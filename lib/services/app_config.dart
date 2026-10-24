// 应用配置的持久化与内存缓存。
//
// 配置文件：App 私有目录下的 config.json。
// 启动时由 main() 调用 AppConfig.init() 载入；之后：
// - 读：AppConfig.appVersion、AppConfig.questionBankDirs；
// - 写：add/remove/set 方法，改完立即落盘并通知界面。
import 'dart:convert'; // JSON 编解码：jsonDecode、JsonEncoder
import 'dart:io'; // 文件与路径：File、Platform

import 'package:flutter/foundation.dart'; // 日志输出：debugPrint
import 'package:path_provider/path_provider.dart'; // getApplicationSupportDirectory

/// 应用配置，全局单例。
///
/// 负责 config.json 的读写：
/// - 启动时调用 init()，把文件内容读进内存；文件不存在就创建；
/// - 读用静态 getter，任何文件都能直接访问；
/// - 写用静态方法，改完内存立即写回文件。
class AppConfig {
  AppConfig._(); // 私有构造，禁止外部 new，只能通过静态成员访问

  static final AppConfig _instance = AppConfig._(); // 进程内唯一实例，保存内存状态和文件句柄

  static const String _fileName = 'config.json'; // 文件名，存在 App 私有目录
  static const String _defaultAppVersion = '1.0.0'; // 文件不存在或字段缺失时的默认版本
  

  String _appVersion = _defaultAppVersion; // 内存中的 App 版本，形如 1.0.0
  List<String> _questionBankDirs = <String>[]; // 内存中的题库目录列表，顺序与文件一致
  int _clockOn = 0; // 连续打卡天数
  String _lastClockOnDate = ''; // 上次打卡日期，格式 yyyy-MM-dd；空表示从未打卡
  File? _file; // config.json 的句柄，init() 成功定位后才非空
  bool _loaded = false; // 是否已完成加载，防止重复读文件

  /// 题库目录的全局实时值：任何页面监听它，目录变化后都会自动重建。
  /// 初始为空，AppConfig.init() 完成后才会填入文件里的数据。
  static final ValueNotifier<List<String>> questionBankDirsNotifier =
      ValueNotifier<List<String>>(const <String>[]);

  static final ValueNotifier<int> clockOnNotifier =
      ValueNotifier<int>(0);

  /// 当前 App 版本，全局可读。
  static String get appVersion => _instance._appVersion;

  /// 当前连续打卡天数，全局可读。
  static int get clockOn => _instance._clockOn;

  /// 上次打卡日期，格式 yyyy-MM-dd；空字符串表示还没打过。
  static String get lastClockOnDate => _instance._lastClockOnDate;

  /// 今天是否已经打过卡。
  static bool get hasCheckedInToday =>
      _instance._lastClockOnDate == _todayString();

  /// 题库目录列表的只读副本，全局可读。
  ///
  /// 返回的是快照，改它不会影响内部状态；修改请用 add/remove/set 方法。
  static List<String> get questionBankDirs =>
      List<String>.unmodifiable(_instance._questionBankDirs);

  /// 启动时调用一次：读配置到内存，没有文件就创建。
  static Future<void> init() => _instance._load();

  /// 修改 App 版本，并立即写入文件。
  static Future<void> setAppVersion(String value) async {
    _instance._appVersion = value; // 先改内存，读取立即生效
    await _instance._save(); // 再落盘
  }

  /// 修改打卡，并立即写入文件。
  ///
  /// 注意：这个方法只改天数、不改“上次打卡日期”，
  /// 日常打卡应该用 [checkInToday]，否则连续天数判断会失效。
  static Future<void> setClockOn(int value) async {
    _instance._clockOn = value; // 先改内存，读取立即生效
    await _instance._save(); // 再落盘
  }

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

  /// 整体替换题库目录列表，并立即写入文件；适合排序、批量导入。
  static Future<void> setQuestionBankDirs(List<String> dirs) async {
    _instance._questionBankDirs = List<String>.from(dirs); // 复制一份，避免外部后续改传入的列表影响内部
    await _instance._save();
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

  /// 手动保存，一般不需要调用，add/remove/set 内部已经保存。
  static Future<void> save() => _instance._save();

  /// 把内存里的目录同步到全局可监听值，通知所有监听页面。
  void _syncNotifier() {
    questionBankDirsNotifier.value =
        List<String>.unmodifiable(_questionBankDirs);
    clockOnNotifier.value = _clockOn;
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
          _appVersion = data['appVersion'] as String? ?? _defaultAppVersion; // 缺失或类型不对就用默认值
          final dirs = data['questionBankDirs'];
          _questionBankDirs =
              dirs is List ? dirs.whereType<String>().toList() : <String>[]; // 只收集字符串项，忽略脏数据
          final clockOn = data['clockOnNum'];
          _clockOn = clockOn is num ? clockOn.toInt() : 0; // 缺失或类型不对就用默认值
          final lastDate = data['lastClockOnDate'];
          _lastClockOnDate = lastDate is String ? lastDate : ''; // 空表示从未打卡
        }
      } else {
        // 没有文件：用默认值写一份，此时内存里已经是默认值
        await _save();
      }
    } catch (error) {
      // 文件损坏、读取失败等：不阻塞启动，退回默认值并覆盖成合法文件
      debugPrint('读取配置失败，使用默认值：$error');
      _appVersion = _defaultAppVersion;
      _questionBankDirs = <String>[];
      _clockOn = 0;
      _lastClockOnDate = '';
      await _save();
    } finally {
      _loaded = true; // 无论成功失败都标记完成，避免反复重试
      _syncNotifier(); // 通知所有页面刷新目录列表
    }
  }

  /// 把内存中的配置序列化后写入文件。
  Future<void> _save() async {
    final file = _file;
    if (file == null) return; // 还没定位到文件（例如 init 失败）时无法保存

    try {
      final content = const JsonEncoder.withIndent('  ').convert(<String, dynamic>{
        'appVersion': _appVersion, // 写入当前版本
        'questionBankDirs': _questionBankDirs, // 写入当前目录列表，顺序保持一致
        'clockOnNum': _clockOn, // 连续打卡天数
        'lastClockOnDate': _lastClockOnDate, // 上次打卡日期 yyyy-MM-dd
      });
      await file.writeAsString(content, flush: true); // 覆盖写并刷新到系统
    } catch (error) {
      debugPrint('保存配置失败：$error'); // 写失败只记日志，不影响界面继续使用
    }
    _syncNotifier(); // 通知所有页面刷新目录列表，即使写失败也要通知，避免界面显示过时数据
  }
}