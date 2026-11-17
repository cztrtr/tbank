import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'atomic_write.dart';

/// 某一天的答题汇总。
class StudyDay {
  const StudyDay({
    required this.date,
    required this.attempts,
    required this.wrong,
  });

  final DateTime date;
  final int attempts;
  final int wrong;

  int get correct => attempts - wrong;

  double? get accuracy => attempts == 0 ? null : correct / attempts;
}

/// 按天聚合的学习历史。
class StudyHistoryData {
  StudyHistoryData(Iterable<StudyDay> days)
    : _days = <String, StudyDay>{
        for (final StudyDay day in days) _key(day.date): day,
      };

  final Map<String, StudyDay> _days;

  static String _key(DateTime date) {
    final String month = date.month.toString().padLeft(2, '0');
    final String day = date.day.toString().padLeft(2, '0');
    return '${date.year}-$month-$day';
  }

  static DateTime _dateOnly(DateTime date) =>
      DateTime(date.year, date.month, date.day);

  StudyDay? dayOf(DateTime date) => _days[_key(date)];

  /// 从今天往前 [count] 天，按时间从早到晚返回；没有记录的日期补 0。
  List<StudyDay> recentDays(int count) {
    final DateTime today = _dateOnly(DateTime.now());
    return <StudyDay>[
      for (int offset = count - 1; offset >= 0; offset--)
        _dayWithZero(today.subtract(Duration(days: offset))),
    ];
  }

  StudyDay _dayWithZero(DateTime date) {
    return _days[_key(date)] ??
        StudyDay(date: _dateOnly(date), attempts: 0, wrong: 0);
  }

  StudyDay get today => _dayWithZero(DateTime.now());

  int get totalAttempts =>
      _days.values.fold<int>(0, (int sum, StudyDay day) => sum + day.attempts);

  int get totalWrong =>
      _days.values.fold<int>(0, (int sum, StudyDay day) => sum + day.wrong);

  /// 从今天（或最近有记录的一天）开始连续有作答的天数。
  int get currentStreak {
    DateTime cursor = _dateOnly(DateTime.now());
    if ((_days[_key(cursor)]?.attempts ?? 0) == 0) {
      cursor = cursor.subtract(const Duration(days: 1));
    }
    int streak = 0;
    while ((_days[_key(cursor)]?.attempts ?? 0) > 0) {
      streak++;
      cursor = cursor.subtract(const Duration(days: 1));
    }
    return streak;
  }

  bool get isEmpty => _days.isEmpty;
}

class _MutableDay {
  int attempts = 0;
  int wrong = 0;
}

/// 逐日学习历史，独立于题库 JSON 保存，避免每答一题都重写整个配置。
class StudyHistory {
  StudyHistory._();

  static const String _fileName = 'study_history.json';
  static const int _retainDays = 180;

  static final Map<String, _MutableDay> _cache = <String, _MutableDay>{};
  static Future<void> _writeChain = Future<void>.value();
  static Future<File?>? _fileFuture;

  /// 管理页/我的页监听它即可实时刷新学习历史摘要。
  static final ValueNotifier<StudyHistoryData> notifier =
      ValueNotifier<StudyHistoryData>(
        StudyHistoryData(const <StudyDay>[]),
      );

  static String _key(DateTime date) {
    final String month = date.month.toString().padLeft(2, '0');
    final String day = date.day.toString().padLeft(2, '0');
    return '${date.year}-$month-$day';
  }

  static DateTime _dateOnly(DateTime date) =>
      DateTime(date.year, date.month, date.day);

  static Future<File?> _file() {
    return _fileFuture ??= () async {
      try {
        final Directory dir = await getApplicationSupportDirectory();
        return File('${dir.path}${Platform.pathSeparator}$_fileName');
      } catch (error) {
        debugPrint('定位学习历史文件失败：$error');
        return null;
      }
    }();
  }

  static Future<void> _ensureLoaded() async {
    final File? file = await _file();
    if (file == null || _cache.isNotEmpty) return;
    if (!await file.exists()) return;

    try {
      final dynamic decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return;
      final dynamic rawDays = decoded['days'];
      if (rawDays is! Map) return;
      for (final MapEntry<dynamic, dynamic> entry in rawDays.entries) {
        final dynamic value = entry.value;
        if (value is! Map) continue;
        final int attempts = value['attempts'] is num
            ? (value['attempts'] as num).toInt()
            : 0;
        final int wrong = value['wrong'] is num
            ? (value['wrong'] as num).toInt()
            : 0;
        if (attempts <= 0) continue;
        _cache[entry.key.toString()] = _MutableDay()
          ..attempts = attempts
          ..wrong = wrong.clamp(0, attempts).toInt();
      }
    } catch (error) {
      debugPrint('读取学习历史失败：$error');
    }
  }

  /// 读取历史；失败时返回空数据，不影响统计页其它部分。
  static Future<StudyHistoryData> load() async {
    await _writeChain;
    try {
      await _ensureLoaded();
    } catch (error) {
      debugPrint('加载学习历史失败：$error');
    }
    final StudyHistoryData data = _toData();
    notifier.value = data;
    return data;
  }

  static StudyHistoryData _toData() {
    return StudyHistoryData(
      _cache.entries.map(
        (MapEntry<String, _MutableDay> entry) => StudyDay(
          date: DateTime.parse(entry.key),
          attempts: entry.value.attempts,
          wrong: entry.value.wrong,
        ),
      ),
    );
  }

  /// 记一次作答；多次调用按队列串行落盘，避免并发覆盖。
  static Future<void> recordAnswer({required bool correct, DateTime? at}) {
    final DateTime date = _dateOnly(at ?? DateTime.now());
    _writeChain = _writeChain.then((_) async {
      try {
        await _ensureLoaded();
        final _MutableDay day = _cache.putIfAbsent(
          _key(date),
          () => _MutableDay(),
        );
        day.attempts += 1;
        if (!correct) day.wrong += 1;
        await _save();
        notifier.value = _toData();
      } catch (error) {
        debugPrint('记录学习历史失败：$error');
      }
    });
    return _writeChain;
  }

  static Future<void> _save() async {
    final File? file = await _file();
    if (file == null) return;

    final DateTime cutoff = _dateOnly(
      DateTime.now().subtract(const Duration(days: _retainDays)),
    );
    _cache.removeWhere((String key, _MutableDay _) {
      try {
        return DateTime.parse(key).isBefore(cutoff);
      } catch (_) {
        return true;
      }
    });

    final Map<String, Map<String, int>> days = <String, Map<String, int>>{};
    for (final MapEntry<String, _MutableDay> entry in _cache.entries) {
      days[entry.key] = <String, int>{
        'attempts': entry.value.attempts,
        'wrong': entry.value.wrong,
      };
    }
    final String content = const JsonEncoder.withIndent('  ')
        .convert(<String, dynamic>{'version': 1, 'days': days});
    await AtomicWrite.writeText(file.path, content);
  }
}
