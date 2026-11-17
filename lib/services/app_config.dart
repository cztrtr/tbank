// 应用配置的持久化与内存缓存。
//
// 配置文件：App 私有目录下的 config.json。
// 启动时由 main() 调用 AppConfig.init() 载入；之后：
// - 读：通过 getter 或 ValueNotifier；
// - 写：add/remove/set 方法，改完立即落盘并通知界面。
//
// API Key 不再以 base64 形式长期保存在 config.json 里：优先写入系统安全存储
// （Android Keystore / Windows DPAPI），只有迁移失败时才保留旧字段并给出警告。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'atomic_write.dart';
import 'secret_store.dart';

/// DeepSeek API Key 当前的存储状态。
enum DsApiKeyStatus {
  /// 未配置。
  none,

  /// 已写入系统安全存储。
  secure,

  /// 迁移失败，仍使用旧版 base64 字段。
  legacyFallback,

  /// 配置标记为 secure，但安全存储里读不到（Keystore 重置/换机恢复）。
  missingAfterRestore,

  /// 当前平台的安全存储不可用。
  unavailable,
}

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
  static const int _configVersion = 2;

  List<String> _questionBankDirs = <String>[]; // 内存中的题库目录列表，顺序与文件一致
  int _clockOn = 0; // 连续打卡天数
  String _lastClockOnDate = ''; // 上次打卡日期，格式 yyyy-MM-dd；空表示从未打卡
  File? _file; // config.json 的句柄，init() 成功定位后才非空
  bool _loaded = false; // 是否已完成加载，防止重复读文件
  String? _dsApiKey; // 内存中的 DS API Key（只在进程内明文缓存，供请求使用）
  DsApiKeyStatus _dsKeyStatus = DsApiKeyStatus.none;
  String? _dsKeyWarning; // 给设置页展示的 Key 存储警告
  SecretStore _secretStore = FlutterSecretStore();
  int _penDoubleTapMs = penDoubleTapDefault; // 笔尖双击切换笔/橡皮的时间窗（毫秒）
  bool _penOnlyInput = false; // 手写板是否只接受手写笔（屏蔽手指落笔）
  double _penScratchWidth = penScratchWidthDefault; // 手写板默认笔宽
  String _penEraserMode = 'pixel'; // 手写板橡皮模式：pixel 精确 / stroke 整笔
  bool _penGrid = true; // 手写板是否显示网格
  Set<String> _collapsedManagerGroups = <String>{}; // 管理页折叠的分组 key

  /// 最近一次配置写盘失败的原因；null 表示成功。
  ///
  /// 界面（添加目录、保存 Key）可以读它判断是否真的落盘，避免「提示成功但
  /// 重启后丢失」。
  static String? _lastSaveError;

  /// 最近一次加载时的提示，例如「配置损坏，已从备份恢复」。
  static String? _loadWarning;

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

  static final ValueNotifier<int> clockOnNotifier = ValueNotifier<int>(0);

  /// Key 是否已配置/存储状态。这里只广播状态，**不广播明文**，
  /// 避免 DevTools、监听者或日志意外拿到 Key。
  static final ValueNotifier<DsApiKeyStatus> dsApiKeyStatusNotifier =
      ValueNotifier<DsApiKeyStatus>(DsApiKeyStatus.none);

  /// 今天是否已经打过卡。
  static bool get hasCheckedInToday =>
      _instance._lastClockOnDate == _todayString();

  /// DS API Key，仅供请求层读取；界面不要使用。
  static String? get dsApiKey => _instance._dsApiKey;

  /// 是否已配置 Key。
  static bool get hasDsApiKey => (_instance._dsApiKey ?? '').trim().isNotEmpty;

  /// Key 当前保存在哪里。
  static DsApiKeyStatus get dsApiKeyStatus => _instance._dsKeyStatus;

  /// Key 存储相关的警告文本；null 表示正常。
  static String? get dsApiKeyWarning => _instance._dsKeyWarning;

  /// 最近一次配置写入失败的原因；null 表示成功。
  static String? get lastSaveError => _lastSaveError;

  /// 最近一次加载配置时的提示（例如从备份恢复）。
  static String? get loadWarning => _loadWarning;

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

  /// 管理页已折叠的分组 key（父文件夹/目录/子目录）。
  static Set<String> get collapsedManagerGroups =>
      Set<String>.unmodifiable(_instance._collapsedManagerGroups);

  /// 保存管理页折叠状态；key 由页面按层级生成。
  static Future<void> setCollapsedManagerGroups(Iterable<String> groups) async {
    _instance._collapsedManagerGroups = groups.toSet();
    await _instance._save();
  }

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
        ? _instance._clockOn +
              1 // 连续打卡
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

  /// 把明文 API Key 转成 base64，仅用于兼容旧版配置。
  ///
  /// 注意：base64 只是编码，不是加密。新版只在安全存储不可用时保留它，
  /// 并在设置页明确提示用户。
  static String? _encodeApiKey(String? value) {
    if (value == null || value.isEmpty) return null;
    return base64Encode(utf8.encode(value));
  }

  /// 把旧版 config.json 里的 dsApiKey（base64）解回明文；无效值返回 null。
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
    if (!_instance._questionBankDirs.remove(path)) {
      return; // remove 返回 false 说明本来就没有
    }
    await _instance._save();
  }

  /// 修改 DS API Key：写入系统安全存储，并清理旧版 base64 字段。
  ///
  /// 传 null 或空串表示清除。
  ///
  /// 返回 false 表示**没有保存成功**（安全存储不可用、读写校验失败、
  /// 配置写盘失败等）；此时内存和磁盘上的旧 Key 保持不变，界面应提示用户。
  static Future<bool> setDsApiKey(String? value) async {
    final String next = (value ?? '').trim();
    if (next.isEmpty) return _clearApiKey();

    if (next.length > 512 || RegExp(r'\s').hasMatch(next)) {
      _instance._dsKeyWarning = 'API Key 格式不正确（不能包含空白字符，长度不超过 512）';
      dsApiKeyStatusNotifier.value = _instance._dsKeyStatus;
      return false;
    }

    try {
      // 先写安全存储并读回校验，确认无误后再更新内存/配置。
      await _instance._secretStore.write(SecretKeys.dsApiKey, next);
      final String? check = await _instance._secretStore.read(
        SecretKeys.dsApiKey,
      );
      if (check != next) {
        throw const SecretStoreException('corrupted', '写入后读回校验失败');
      }

      _instance._dsApiKey = next;
      _instance._dsKeyStatus = DsApiKeyStatus.secure;
      _instance._dsKeyWarning = null;
      final bool saved = await _instance._save();
      if (saved) {
        // 旧配置备份里可能还有 base64 Key，迁移成功后清掉。
        final File? file = _instance._file;
        if (file != null) await AtomicWrite.deleteBackup(file.path);
      }
      return saved;
    } on SecretStoreException catch (error) {
      _instance._dsKeyWarning = error.message;
      dsApiKeyStatusNotifier.value = _instance._dsKeyStatus;
      return false;
    } catch (error) {
      // 不打印 error.toString()，避免异常里夹带敏感信息。
      _instance._dsKeyWarning = '保存 API Key 失败';
      dsApiKeyStatusNotifier.value = _instance._dsKeyStatus;
      debugPrint('保存 API Key 失败（已脱敏）');
      return false;
    }
  }

  /// 清除 Key：安全存储删除成功后才清内存和配置。
  static Future<bool> _clearApiKey() async {
    try {
      await _instance._secretStore.delete(SecretKeys.dsApiKey);
    } on SecretStoreException catch (error) {
      _instance._dsKeyWarning = error.message;
      dsApiKeyStatusNotifier.value = _instance._dsKeyStatus;
      return false;
    }

    _instance._dsApiKey = null;
    _instance._dsKeyStatus = DsApiKeyStatus.none;
    _instance._dsKeyWarning = null;
    final bool saved = await _instance._save();
    final File? file = _instance._file;
    if (file != null) await AtomicWrite.deleteBackup(file.path);
    return saved;
  }

  /// 修改笔尖双击间隔；超出范围会被夹到 150~700ms。
  static Future<void> setPenDoubleTapMs(int value) async {
    _instance._penDoubleTapMs = value
        .clamp(penDoubleTapMin, penDoubleTapMax)
        .toInt();
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
  ///
  /// 注意：目录列表是 List，ValueNotifier 用 `==` 比较，直接赋新实例会
  /// 让「保存手写设置」也触发题库页重新扫描。这里先比较内容，只有目录
  /// 真的变化才赋新值。
  void _syncNotifier() {
    final List<String> dirs = List<String>.unmodifiable(_questionBankDirs);
    if (!listEquals(questionBankDirsNotifier.value, dirs)) {
      questionBankDirsNotifier.value = dirs;
    }
    if (clockOnNotifier.value != _clockOn) {
      clockOnNotifier.value = _clockOn;
    }
    if (dsApiKeyStatusNotifier.value != _dsKeyStatus) {
      dsApiKeyStatusNotifier.value = _dsKeyStatus;
    }
  }

  /// 真正的加载逻辑：定位目录、读文件、解析、填内存。
  Future<void> _load() async {
    if (_loaded) return; // 已加载过就跳过，保证 init() 幂等

    _loadWarning = null;
    bool needSave = false;
    try {
      final dir = await getApplicationSupportDirectory(); // App 私有目录，无需存储权限
      await dir.create(recursive: true); // 目录不存在时递归创建，已存在不报错
      _file = File(
        '${dir.path}${Platform.pathSeparator}$_fileName',
      ); // 拼出 config.json 的完整路径

      Map<String, dynamic>? data;
      if (await _file!.exists()) {
        try {
          data = _decodeConfig(await _file!.readAsString());
        } catch (error) {
          debugPrint('读取配置失败，尝试备份：${error.runtimeType}');
        }
      }

      // 主文件损坏/缺失时尝试 .bak；备份恢复成功后不覆盖现场，只提示。
      if (data == null) {
        final String? backupText = await AtomicWrite.readBackupText(
          _file!.path,
        );
        if (backupText != null) {
          try {
            data = _decodeConfig(backupText);
            _loadWarning = '配置文件损坏，已从备份恢复。';
            needSave = true;
          } catch (error) {
            debugPrint('备份配置也无法解析：${error.runtimeType}');
          }
        }
      }

      if (data != null) {
        _applyConfig(data);
        final String? legacy = _decodeApiKey(data['dsApiKey']);
        await _loadApiKey(legacy);
      } else {
        // 没有任何可用配置：先把损坏文件脱敏归档，再写一份默认配置。
        await _archiveBadConfig();
        await _loadApiKey(null);
        needSave = true;
      }

      if (needSave) await _save();
    } catch (error) {
      // 文件损坏、读取失败等：不阻塞启动，退回默认值并覆盖成合法文件
      debugPrint('读取配置失败，使用默认值：${error.runtimeType}');
      _resetToDefaults();
      _loadWarning = '读取配置失败，已使用默认设置。';
      await _save();
    } finally {
      _loaded = true; // 无论成功失败都标记完成，避免反复重试
      _syncNotifier(); // 通知所有页面刷新配置
    }
  }

  /// 解析 config.json；根节点不是对象时抛 [FormatException]。
  Map<String, dynamic> _decodeConfig(String raw) {
    final dynamic decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw const FormatException('配置根节点必须是 JSON 对象');
    }
    return Map<String, dynamic>.from(decoded);
  }

  /// 把解析好的字段填进内存；缺失字段保留默认值。
  void _applyConfig(Map<String, dynamic> data) {
    final dirs = data['questionBankDirs'];
    _questionBankDirs = dirs is List
        ? dirs.whereType<String>().toList()
        : <String>[];

    final clockOn = data['clockOnNum'];
    _clockOn = clockOn is num ? clockOn.toInt() : 0;

    final lastDate = data['lastClockOnDate'];
    _lastClockOnDate = lastDate is String ? lastDate : '';

    final penDoubleTapMs = data['penDoubleTapMs'];
    _penDoubleTapMs = penDoubleTapMs is num
        ? penDoubleTapMs
              .toInt()
              .clamp(penDoubleTapMin, penDoubleTapMax)
              .toInt()
        : penDoubleTapDefault;
    _penOnlyInput = data['penOnlyInput'] == true;
    final penWidth = data['penScratchWidth'];
    _penScratchWidth = penWidth is num
        ? penWidth
              .toDouble()
              .clamp(penScratchWidthMin, penScratchWidthMax)
              .toDouble()
        : penScratchWidthDefault;
    _penEraserMode = data['penEraserMode'] == 'stroke'
        ? 'stroke'
        : 'pixel';
    _penGrid = data['penGrid'] != false;
    final collapsedGroups = data['collapsedManagerGroups'];
    _collapsedManagerGroups = collapsedGroups is List
        ? collapsedGroups.whereType<String>().toSet()
        : <String>{};
  }

  /// 加载 Key：优先系统安全存储，旧版 base64 自动迁移。
  Future<void> _loadApiKey(String? legacy) async {
    String? secure;
    bool secureReadFailed = false;
    try {
      secure = await _secretStore.read(SecretKeys.dsApiKey);
    } on SecretStoreException catch (error) {
      secureReadFailed = true;
      _dsKeyWarning = error.message;
    }

    if (secure != null && secure.trim().isNotEmpty) {
      _dsApiKey = secure.trim();
      _dsKeyStatus = DsApiKeyStatus.secure;
      // 两边都有时 secure 优先，顺手清掉旧字段，避免旧值复活。
      if (legacy != null) await _scrubLegacyKey();
      return;
    }

    if (legacy != null && legacy.trim().isNotEmpty) {
      final String value = legacy.trim();
      try {
        await _secretStore.write(SecretKeys.dsApiKey, value);
        final String? check = await _secretStore.read(SecretKeys.dsApiKey);
        if (check != value) {
          throw const SecretStoreException('corrupted', '迁移后读回校验失败');
        }
        _dsApiKey = value;
        _dsKeyStatus = DsApiKeyStatus.secure;
        _dsKeyWarning = null;
        await _scrubLegacyKey();
      } on SecretStoreException catch (error) {
        // 迁移失败不丢 Key：继续用旧字段，但设置页会提示风险。
        _dsApiKey = value;
        _dsKeyStatus = DsApiKeyStatus.legacyFallback;
        _dsKeyWarning = '${error.message}；当前仍以旧方式保存在 config.json';
      }
      return;
    }

    _dsApiKey = null;
    if (secureReadFailed) {
      _dsKeyStatus = DsApiKeyStatus.unavailable;
    } else {
      _dsKeyStatus = DsApiKeyStatus.none;
    }
  }

  /// 删除 config.json 里的旧版 dsApiKey，并清掉可能含 Key 的备份。
  Future<void> _scrubLegacyKey() async {
    await _save();
    final File? file = _file;
    if (file != null) await AtomicWrite.deleteBackup(file.path);
  }

  /// 把损坏的 config.json 脱敏后归档为 config.bad.<时间戳>.json。
  Future<void> _archiveBadConfig() async {
    final File? file = _file;
    if (file == null || !await file.exists()) return;
    try {
      final String raw = await file.readAsString();
      // 即使 JSON 已经坏了，也尽量用正则去掉 dsApiKey 的值。
      final String redacted = raw.replaceAllMapped(
        RegExp(r'"dsApiKey"\s*:\s*"(?:[^"\\]|\\.)*"'),
        (_) => '"dsApiKey": null',
      );
      final File archive = File(
        '${file.path}.bad.${DateTime.now().millisecondsSinceEpoch}.json',
      );
      await archive.writeAsString(redacted, flush: true);
      await file.delete();
    } catch (error) {
      debugPrint('归档损坏配置失败：${error.runtimeType}');
    }
  }

  void _resetToDefaults() {
    _questionBankDirs = <String>[];
    _clockOn = 0;
    _lastClockOnDate = '';
    _dsApiKey = null;
    _dsKeyStatus = DsApiKeyStatus.none;
    _dsKeyWarning = null;
    _penDoubleTapMs = penDoubleTapDefault;
    _penOnlyInput = false;
    _penScratchWidth = penScratchWidthDefault;
    _penEraserMode = 'pixel';
    _penGrid = true;
    _collapsedManagerGroups = <String>{};
  }

  /// 把内存中的配置序列化后写入文件。
  ///
  /// 使用 [AtomicWrite]：先写临时文件再替换，避免写一半留下坏 JSON。
  /// 返回 false 表示没有写成功；错误原因放在 [lastSaveError]。
  Future<bool> _save() async {
    final file = _file;
    if (file == null) {
      _lastSaveError = '配置目录不可用';
      return false;
    }

    try {
      final Map<String, dynamic> data = <String, dynamic>{
        'configVersion': _configVersion,
        'questionBankDirs': _questionBankDirs,
        'clockOnNum': _clockOn,
        'lastClockOnDate': _lastClockOnDate,
        'dsApiKeyStorage': _dsKeyStatus.name,
        'penDoubleTapMs': _penDoubleTapMs,
        'penOnlyInput': _penOnlyInput,
        'penScratchWidth': _penScratchWidth,
        'penEraserMode': _penEraserMode,
        'penGrid': _penGrid,
        'collapsedManagerGroups': _collapsedManagerGroups.toList()..sort(),
        // 只有迁移失败、明确回退时才继续写 base64；正常情况不落盘 Key。
        if (_dsKeyStatus == DsApiKeyStatus.legacyFallback)
          'dsApiKey': _encodeApiKey(_dsApiKey),
      };
      final String content = const JsonEncoder.withIndent('  ').convert(data);
      await AtomicWrite.writeText(file.path, content);
      _lastSaveError = null;
      _syncNotifier();
      return true;
    } catch (error) {
      // 只记录异常类型，不打印可能包含路径/内容的 error.toString()。
      _lastSaveError = '保存配置失败（${error.runtimeType}）';
      debugPrint(_lastSaveError!);
      _syncNotifier(); // 即使写失败也通知，避免界面显示过时数据
      return false;
    }
  }

  // ---------------------------------------------------------------- 测试辅助

  /// 只给测试用：替换安全存储实现，避免依赖真实 Keystore/DPAPI。
  static void setSecretStoreForTest(SecretStore store) {
    _instance._secretStore = store;
  }

  /// 只给测试用：把单例恢复到「未加载」状态。
  static void resetForTest() {
    _instance._loaded = false;
    _instance._file = null;
    _lastSaveError = null;
    _loadWarning = null;
    _instance._resetToDefaults();
    _instance._secretStore = MemorySecretStore();
    questionBankDirsNotifier.value = const <String>[];
    clockOnNotifier.value = 0;
    dsApiKeyStatusNotifier.value = DsApiKeyStatus.none;
  }
}
