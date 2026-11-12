// 应用配置的持久化与内存缓存。
//
// 配置文件：App 私有目录下的 config.json。
// 启动时由 main() 调用 AppConfig.init() 载入；之后：
// - 读：通过 getter 或 ValueNotifier；
// - 写：add/remove/set 方法，改完立即落盘并通知界面。
import 'dart:convert'; // JSON 编解码、base64
import 'dart:io'; // 文件与路径：File、Platform

import 'package:flutter/foundation.dart'; // 日志输出：debugPrint
import 'package:path_provider/path_provider.dart'; // getApplicationSupportDirectory

/// 应用配置，全局单例。
///
/// 负责 config.json 的读写：
/// - 启动时调用 init()，把文件内容读进内存；文件不存在就创建；
/// - 读用静态 getter 或 ValueNotifier；
/// - 写用静态方法，改完内存立即写回文件。
class AppConfig {
  AppConfig._(); // 私有构造，禁止外部 new，只能通过静态成员访问

  static final AppConfig _instance = AppConfig._(); // 进程内唯一实例，保存内存状态和文件句柄

  static const String _fileName = 'config.json'; // 文件名，存在 App 私有目录

  List<String> _questionBankDirs = <String>[]; // 内存中的题库目录列表，顺序与文件一致
  int _clockOn = 0; // 连续打卡天数
  String _lastClockOnDate = ''; // 上次打卡日期，格式 yyyy-MM-dd；空表示从未打卡
  File? _file; // config.json 的句柄，init() 成功定位后才非空
  bool _loaded = false; // 是否已完成加载，防止重复读文件
  String? _dsApiKey; // 内存中的 DS API Key（明文）；持久化时转 base64 再写入 config.json
  int _penDoubleTapMs = penDoubleTapDefault; // 笔尖双击切换笔/橡皮的时间窗（毫秒）
  bool _penOnlyInput = false; // 手写板是否只接受手写笔（屏蔽手指落笔）
  double _penScratchWidth = penScratchWidthDefault; // 手写板默认笔宽
  String _penEraserMode = 'pixel'; // 手写板橡皮模式：pixel 精确 / stroke 整笔
  bool _penGrid = true; // 手写板是否显示网格

  /// 手写板笔宽的默认值与允许范围。
  static const double penScratchWidthDefault = 3;
  static const double penScratchWidthMin = 1;
  static const double penScratchWidthMax = 12;

  /// 笔尖双击间隔的默认值，也是设置页滑块的初始位置。
  static const int penDoubleTapDefault = 320;

  /// 笔尖双击间隔的允许范围，存储和读取都会夹到这个区间。
  static const int penDoubleTapMin = 150;
  static const int penDoubleTapMax = 700;

  /// 题库目录的全局实时值：任何页面监听它，目录变化后都会自动重建。
  /// 初始为空，AppConfig.init() 完成后才会填入文件里的数据。
  static final ValueNotifier<List<String>> questionBankDirsNotifier =
      ValueNotifier<List<String>>(const <String>[]);

  static final ValueNotifier<int> clockOnNotifier =
      ValueNotifier<int>(0);

  /// DS API Key 的全局实时值；设置后监听它的页面会自动刷新。
  ///
  /// 这里存的是明文，只有在 config.json 里才以 base64 形式保存。
  static final ValueNotifier<String?> dsApiKeyNotifier =
      ValueNotifier<String?>(null);

  /// 今天是否已经打过卡。
  static bool get hasCheckedInToday =>
      _instance._lastClockOnDate == _todayString();

  /// DS API Key，全局可读。
  static String? get dsApiKey => _instance._dsApiKey;

  /// 笔尖双击切换笔/橡皮的时间窗（毫秒），插件通过 context.settings 读取。
  static int get penDoubleTapMs => _instance._penDoubleTapMs;

  /// 手写板是否屏蔽手指：true 时只有手写笔/橡皮端能落笔，
  /// 手指触摸不画线（仍然可以用手指滚动页面）。
  static bool get penOnlyInput => _instance._penOnlyInput;

  /// 手写板默认笔宽；插件里调过之后会存下来，换题库 / 换题组继续沿用。
  static double get penScratchWidth => _instance._penScratchWidth;

  /// 手写板橡皮模式：`pixel` 只挖掉笔迹，`stroke` 整条删除。
  static String get penEraserMode => _instance._penEraserMode;

  /// 手写板是否显示网格。
  static bool get penGrid => _instance._penGrid;

  /// 启动时调用一次：读配置到内存，没有文件就创建。
  static Future<void> init() => _instance._load();

  /// 完成今天的打卡，返回是否真的新增了一天。
  ///
  /// - 今天已经打过：返回 false，不修改任何数据；
  /// - 上次打卡是昨天：连续天数 +1；
  /// - 其它情况（从未打卡、断签、日期异常）：连续天数重置为 1。
  ///
  /// 两个字段在同一次 `_save()` 里写入，避免“天数变了但日期没变”。
  static Future<bool> checkInToday() async {
    final today = _todayString();

    // 今天已经打过，直接拒绝，保证重复点击/重复调用不会多加
    if (_instance._lastClockOnDate == today) {
      return false;
    }

    final nextCount = _instance._lastClockOnDate == _yesterdayString()
        ? _instance._clockOn + 1 // 连续打卡
        : 1; // 断签或第一次打卡

    // 先改内存再落盘；await 之前已经更新日期，
    // 因此并发调用第二次也会看到“今天已打”。
    _instance._clockOn = nextCount;
    _instance._lastClockOnDate = today;

    await _instance._save();
    return true;
  }

  /// 把日期格式化成 yyyy-MM-dd。
  static String _dateString(DateTime date) {
    final year = date.year.toString().padLeft(4, '0');
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '$year-$month-$day';
  }

  /// 今天的日期字符串，按设备本地时间计算。
  static String _todayString() => _dateString(DateTime.now());

  /// 昨天的日期字符串。
  ///
  /// 用日历字段构造，而不是 subtract(Duration(days: 1))，
  /// 避免夏令时或时区切换时算出错误日期。
  static String _yesterdayString() {
    final now = DateTime.now();
    return _dateString(DateTime(now.year, now.month, now.day - 1));
  }

  /// 把明文 API Key 转成 base64 用于存储；空值返回 null。
  ///
  /// 注意：base64 只是编码，不是加密——它只能避免密钥以明文形态躺在
  /// config.json 里被人一眼看到，挡不住主动解码。
  static String? _encodeApiKey(String? value) {
    if (value == null || value.isEmpty) return null;
    return base64Encode(utf8.encode(value));
  }

  /// 把 config.json 里的 dsApiKey（base64）解回明文；无效值返回 null。
  static String? _decodeApiKey(Object? raw) {
    if (raw is! String || raw.isEmpty) return null;
    try {
      return utf8.decode(base64Decode(raw));
    } catch (_) {
      return null; // 不是合法 base64：视为未配置
    }
  }

  /// 追加一个题库目录，已存在则忽略；成功后立即写入文件。
  static Future<void> addQuestionBankDir(String path) async {
    final dirs = _instance._questionBankDirs;
    if (dirs.contains(path)) return; // 去重，避免同一目录出现多次
    dirs.add(path); // 顺序追加到末尾
    await _instance._save();
  }

  /// 删除一个题库目录，不存在则忽略；成功后立即写入文件。
  static Future<void> removeQuestionBankDir(String path) async {
    if (!_instance._questionBankDirs.remove(path)) return; // remove 返回 false 说明本来就没有
    await _instance._save();
  }

  /// 修改 DS API Key：更新内存并写入 config.json（base64 编码后存储）。
  ///
  /// 传 null 或空串表示清除。
  static Future<void> setDsApiKey(String? value) async {
    _instance._dsApiKey =
        (value == null || value.trim().isEmpty) ? null : value.trim();
    await _instance._save(); // 落盘，并在 _syncNotifier 里通知界面
  }

  /// 修改笔尖双击间隔；超出范围会被夹到 150~700ms。
  static Future<void> setPenDoubleTapMs(int value) async {
    _instance._penDoubleTapMs =
        value.clamp(penDoubleTapMin, penDoubleTapMax).toInt();
    await _instance._save();
  }

  /// 修改「手写板只认手写笔」开关；下次打开手写区生效。
  static Future<void> setPenOnlyInput(bool value) async {
    if (_instance._penOnlyInput == value) return; // 值没变就不写盘
    _instance._penOnlyInput = value;
    await _instance._save();
  }

  /// 修改手写板默认笔宽；超出 1~12 会被夹住。
  static Future<void> setPenScratchWidth(double value) async {
    final double next = value
        .clamp(penScratchWidthMin, penScratchWidthMax)
        .toDouble();
    if (_instance._penScratchWidth == next) return;
    _instance._penScratchWidth = next;
    await _instance._save();
  }

  /// 修改手写板橡皮模式；非法值退回 `pixel`。
  static Future<void> setPenEraserMode(String mode) async {
    final String next = mode == 'stroke' ? 'stroke' : 'pixel';
    if (_instance._penEraserMode == next) return;
    _instance._penEraserMode = next;
    await _instance._save();
  }

  /// 修改手写板网格开关。
  static Future<void> setPenGrid(bool value) async {
    if (_instance._penGrid == value) return;
    _instance._penGrid = value;
    await _instance._save();
  }

  /// 一次性保存插件传来的手写板设置；缺的字段保持不变。
  ///
  /// 插件在改笔宽 / 橡皮模式 / 网格时调用，只写盘一次。
  static Future<void> savePenSettings({
    double? width,
    String? eraserMode,
    bool? grid,
  }) async {
    bool changed = false;

    if (width != null) {
      final double next = width
          .clamp(penScratchWidthMin, penScratchWidthMax)
          .toDouble();
      if (_instance._penScratchWidth != next) {
        _instance._penScratchWidth = next;
        changed = true;
      }
    }
    if (eraserMode != null) {
      final String next = eraserMode == 'stroke' ? 'stroke' : 'pixel';
      if (_instance._penEraserMode != next) {
        _instance._penEraserMode = next;
        changed = true;
      }
    }
    if (grid != null && _instance._penGrid != grid) {
      _instance._penGrid = grid;
      changed = true;
    }
    if (changed) await _instance._save();
  }

  /// 把内存里的配置同步到全局可监听值，通知所有监听页面。
  void _syncNotifier() {
    questionBankDirsNotifier.value =
        List<String>.unmodifiable(_questionBankDirs);
    clockOnNotifier.value = _clockOn;
    dsApiKeyNotifier.value = _dsApiKey; // 通知所有页面刷新 DS API Key
  }

  /// 真正的加载逻辑：定位目录、读文件、解析、填内存。
  Future<void> _load() async {
    if (_loaded) return; // 已加载过就跳过，保证 init() 幂等

    try {
      final dir = await getApplicationSupportDirectory(); // App 私有目录，无需存储权限
      await dir.create(recursive: true); // 目录不存在时递归创建，已存在不报错
      _file = File('${dir.path}${Platform.pathSeparator}$_fileName'); // 拼出 config.json 的完整路径

      if (await _file!.exists()) {
        // 已有文件：读取并解析
        final data = jsonDecode(await _file!.readAsString()); // 内容不是合法 JSON 会抛异常
        if (data is Map<String, dynamic>) {
          final dirs = data['questionBankDirs'];
          _questionBankDirs =
              dirs is List ? dirs.whereType<String>().toList() : <String>[]; // 只收集字符串项，忽略脏数据
          final clockOn = data['clockOnNum'];
          _clockOn = clockOn is num ? clockOn.toInt() : 0; // 缺失或类型不对就用默认值
          final lastDate = data['lastClockOnDate'];
          _lastClockOnDate = lastDate is String ? lastDate : ''; // 空表示从未打卡
          _dsApiKey = _decodeApiKey(data['dsApiKey']); // base64 → 明文；无效视为未设置
          final penDoubleTapMs = data['penDoubleTapMs'];
          _penDoubleTapMs = penDoubleTapMs is num
              ? penDoubleTapMs
                    .toInt()
                    .clamp(penDoubleTapMin, penDoubleTapMax)
                    .toInt()
              : penDoubleTapDefault;
          _penOnlyInput = data['penOnlyInput'] == true; // 缺失按「不屏蔽」处理
          final penWidth = data['penScratchWidth'];
          _penScratchWidth = penWidth is num
              ? penWidth
                    .toDouble()
                    .clamp(penScratchWidthMin, penScratchWidthMax)
                    .toDouble()
              : penScratchWidthDefault;
          _penEraserMode =
              data['penEraserMode'] == 'stroke' ? 'stroke' : 'pixel';
          _penGrid = data['penGrid'] != false; // 缺失按「显示网格」处理
        }
      } else {
        // 没有文件：用默认值写一份，此时内存里已经是默认值
        await _save();
      }
    } catch (error) {
      // 文件损坏、读取失败等：不阻塞启动，退回默认值并覆盖成合法文件
      debugPrint('读取配置失败，使用默认值：$error');
      _questionBankDirs = <String>[];
      _clockOn = 0;
      _lastClockOnDate = '';
      _dsApiKey = null;
      _penDoubleTapMs = penDoubleTapDefault;
      _penOnlyInput = false;
      _penScratchWidth = penScratchWidthDefault;
      _penEraserMode = 'pixel';
      _penGrid = true;
      await _save();
    } finally {
      _loaded = true; // 无论成功失败都标记完成，避免反复重试
      _syncNotifier(); // 通知所有页面刷新配置
    }
  }

  /// 把内存中的配置序列化后写入文件。
  Future<void> _save() async {
    final file = _file;
    if (file == null) return; // 还没定位到文件（例如 init 失败）时无法保存

    try {
      final content = const JsonEncoder.withIndent('  ').convert(<String, dynamic>{
        'questionBankDirs': _questionBankDirs, // 题库目录列表，顺序保持一致
        'clockOnNum': _clockOn, // 连续打卡天数
        'lastClockOnDate': _lastClockOnDate, // 上次打卡日期 yyyy-MM-dd
        'dsApiKey': _encodeApiKey(_dsApiKey), // DS API Key（base64 编码后存储）
        'penDoubleTapMs': _penDoubleTapMs, // 笔尖双击间隔（毫秒）
        'penOnlyInput': _penOnlyInput, // 手写板是否屏蔽手指
        'penScratchWidth': _penScratchWidth, // 手写板默认笔宽
        'penEraserMode': _penEraserMode, // 手写板橡皮模式
        'penGrid': _penGrid, // 手写板是否显示网格
      });
      await file.writeAsString(content, flush: true); // 覆盖写并刷新到系统
    } catch (error) {
      debugPrint('保存配置失败：$error'); // 写失败只记日志，不影响界面继续使用
    }
    _syncNotifier(); // 通知所有页面，即使写失败也要通知，避免界面显示过时数据
  }
}
