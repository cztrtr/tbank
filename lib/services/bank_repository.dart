import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/question_bank_file.dart';
import 'ai_question_generator.dart';
import 'app_config.dart';
import 'bank_io.dart';

/// 一次题库扫描的结果。
class BankScanResult {
  const BankScanResult({required this.files, required this.errors});

  /// 扫描到的题库文件（用户目录 + App 内置 AI 题库，按 uri 去重）。
  final List<QuestionBankFile> files;

  /// 读取失败的目录提示；空表示全部成功。
  final List<String> errors;
}

/// 题库扫描的统一入口。
///
/// 管理页、统计页、错题本以前各写了一套「并发列目录 + 合并 AI 题库 + 去重」，
/// 这里收拢成一处，并短暂缓存结果：
/// - 默认 2 秒内复用上次结果（页面之间切换不用重复列目录）；
/// - 传 `refresh: true` 强制重新扫描（目录变化、用户主动刷新时用）；
/// - 并发调用共享同一次扫描，不会重复 IO。
/// 一份题库的统计摘要。
///
/// 由 [BankRepository.loadAnalysis] 在后台 isolate 解析 JSON 后生成，
/// 管理页/统计页复用，避免同一份文件被反复全文解析。
class BankStat {
  const BankStat({
    required this.questionCount,
    required this.practiceCount,
    required this.attemptCount,
    required this.wrongCount,
    this.wrongItems = const <({String question, int wrong})>[],
  });

  final int questionCount;

  /// 整本练习轮数：所有题里最小的作答次数。
  final int practiceCount;

  final int attemptCount;
  final int wrongCount;

  /// 答错过、且题干非空的题目（最多 20 条，供统计页取全局前 5）。
  final List<({String question, int wrong})> wrongItems;

  double? get accuracy =>
      attemptCount == 0 ? null : 1 - wrongCount / attemptCount;
}

class _CachedAnalysis {
  const _CachedAnalysis({
    required this.stat,
    required this.modified,
    required this.size,
    required this.cachedAt,
  });

  final BankStat stat;
  final int modified;
  final int size;
  final DateTime cachedAt;
}

class BankRepository {
  BankRepository._();

  static final BankRepository instance = BankRepository._();

  static const Duration _cacheTtl = Duration(seconds: 2);
  static const Duration _safStatsTtl = Duration(seconds: 60);

  BankScanResult? _cached;
  DateTime? _cachedAt;
  Future<BankScanResult>? _inflight;
  VoidCallback? _onDirsChanged;

  /// 题库统计缓存：uri → 解析结果 + 文件指纹。
  final Map<String, _CachedAnalysis> _analysisCache =
      <String, _CachedAnalysis>{};

  /// 丢弃缓存；题库目录增删后由监听器自动调用。
  void invalidate() {
    _cached = null;
    _cachedAt = null;
    _inflight = null;
    invalidateStats();
  }

  /// 列出所有可见题库。
  ///
  /// [refresh] 为 true 时跳过缓存；同时只跑一次扫描。
  Future<BankScanResult> listAll({bool refresh = false}) {
    _ensureListening();

    final BankScanResult? cached = _cached;
    final DateTime? cachedAt = _cachedAt;
    if (!refresh &&
        cached != null &&
        cachedAt != null &&
        DateTime.now().difference(cachedAt) < _cacheTtl) {
      return Future<BankScanResult>.value(cached);
    }

    final Future<BankScanResult>? inflight = _inflight;
    if (inflight != null) return inflight;

    final Future<BankScanResult> future = _scan();
    _inflight = future;
    unawaited(
      future
          .then<void>(
            (BankScanResult result) {
              _cached = result;
              _cachedAt = DateTime.now();
            },
            onError: (Object error, StackTrace stack) {
              // _scan 自己吞掉了目录异常，这里只防御未预料的错误
              debugPrint('扫描题库失败：$error');
            },
          )
          .whenComplete(() {
            if (identical(_inflight, future)) _inflight = null;
          }),
    );
    return future;
  }

  /// 读取一组题库的统计摘要。
  ///
  /// [refresh] 为 true 时忽略缓存；文件 mtime/size 未变时直接复用。
  /// 解析在后台 isolate 完成，避免大批题库卡住 UI。
  Future<Map<String, BankStat>> loadStats(
    List<QuestionBankFile> files, {
    bool refresh = false,
  }) async {
    final Map<String, BankStat> result = <String, BankStat>{};
    const int concurrency = 6;
    for (int start = 0; start < files.length; start += concurrency) {
      final int end = (start + concurrency).clamp(0, files.length);
      final List<BankStat?> chunk = await Future.wait(
        files
            .sublist(start, end)
            .map(
              (QuestionBankFile file) => _loadAnalysis(file, refresh: refresh),
            ),
      );
      for (int i = 0; i < chunk.length; i++) {
        final BankStat? stat = chunk[i];
        if (stat != null) result[files[start + i].uri] = stat;
      }
    }
    return result;
  }

  final Map<String, Future<BankStat?>> _analysisInflight =
      <String, Future<BankStat?>>{};

  Future<BankStat?> _loadAnalysis(
    QuestionBankFile file, {
    required bool refresh,
  }) async {
    final String uri = file.uri;
    final bool isSaf = uri.startsWith('content://');
    int modified = 0;
    int size = 0;
    if (!isSaf) {
      try {
        final FileStat stat = await File(uri).stat();
        modified = stat.modified.millisecondsSinceEpoch;
        size = stat.size;
      } catch (error) {
        debugPrint('读取题库文件信息失败：${error.runtimeType}');
      }
    }

    final _CachedAnalysis? cached = _analysisCache[uri];
    if (!refresh && cached != null) {
      final bool fresh = isSaf
          ? DateTime.now().difference(cached.cachedAt) < _safStatsTtl
          : cached.modified == modified && cached.size == size;
      if (fresh) return cached.stat;
    }

    final Future<BankStat?>? inflight = _analysisInflight[uri];
    if (inflight != null) return inflight;

    late final Future<BankStat?> future;
    future = () async {
      try {
        final String raw = await BankIo.readText(uri);
        final Map<String, dynamic> parsed = await compute(
          _parseBankAnalysis,
          raw,
        );
        final List<({String question, int wrong})> wrongItems =
            <({String question, int wrong})>[];
        final dynamic rawWrong = parsed['wrongItems'];
        if (rawWrong is List) {
          for (final dynamic item in rawWrong) {
            if (item is! Map) continue;
            wrongItems.add((
              question: item['question']?.toString() ?? '',
              wrong: item['wrong'] is num ? (item['wrong'] as num).toInt() : 0,
            ));
          }
        }
        final BankStat stat = BankStat(
          questionCount: (parsed['questionCount'] as num?)?.toInt() ?? 0,
          practiceCount: (parsed['practiceCount'] as num?)?.toInt() ?? 0,
          attemptCount: (parsed['attemptCount'] as num?)?.toInt() ?? 0,
          wrongCount: (parsed['wrongCount'] as num?)?.toInt() ?? 0,
          wrongItems: wrongItems,
        );
        _analysisCache[uri] = _CachedAnalysis(
          stat: stat,
          modified: modified,
          size: size,
          cachedAt: DateTime.now(),
        );
        return stat;
      } catch (error) {
        debugPrint('解析题库统计失败：$uri ${error.runtimeType}');
        return null;
      } finally {
        if (identical(_analysisInflight[uri], future)) {
          _analysisInflight.remove(uri);
        }
      }
    }();
    _analysisInflight[uri] = future;
    return future;
  }

  /// 扫描结果变化或用户手动刷新时丢弃统计缓存。
  void invalidateStats() {
    _analysisCache.clear();
    _analysisInflight.clear();
  }

  Future<BankScanResult> _scan() async {
    // 从全局 notifier 取最新目录，保证加号新增的目录立即可见
    final List<String> dirs = List<String>.of(
      AppConfig.questionBankDirsNotifier.value,
    );
    final List<QuestionBankFile> files = <QuestionBankFile>[];
    final List<String> errors = <String>[];
    final Set<String> seen = <String>{};

    bool addFile(QuestionBankFile file) {
      // 同一物理目录可能以 tree URI / document URI 两种形式出现；
      // 用目录身份 + 文件名去重，避免递归扫描把同一道题列两遍。
      final String identity =
          '${BankIo.directoryKeyOf(file.directoryRef)}|'
          '${file.name.toLowerCase()}';
      return seen.add(identity);
    }

    // 用户添加的目录并发扫描：单个目录失败只记错误，不影响其它目录
    final List<({List<QuestionBankFile> files, String? error})> results =
        await Future.wait(
          dirs.map((String dirRef) async {
            try {
              final List<QuestionBankFile> found = await BankIo.listJsonFiles(
                dirRef,
                directoryName: BankIo.displayNameOf(dirRef),
                recursive: true,
              );
              return (files: found, error: null as String?);
            } catch (error) {
              return (
                files: const <QuestionBankFile>[],
                error: '读取失败：${BankIo.displayNameOf(dirRef)}（$error）',
              );
            }
          }),
        );

    for (final ({List<QuestionBankFile> files, String? error}) result
        in results) {
      if (result.error != null) errors.add(result.error!);
      for (final QuestionBankFile file in result.files) {
        if (addFile(file)) files.add(file);
      }
    }

    // App 内置的 AI 题库（含拍书出题的二级目录）也显示在列表里
    try {
      for (final QuestionBankFile file
          in await AiQuestionGenerator.listBankFiles()) {
        if (addFile(file)) files.add(file);
      }
    } catch (error) {
      // AI 题库目录异常不影响用户目录的结果
      debugPrint('读取 AI 题库目录失败：$error');
    }

    return BankScanResult(
      files: List<QuestionBankFile>.unmodifiable(files),
      errors: List<String>.unmodifiable(errors),
    );
  }

  /// 目录列表变化时自动丢缓存；只注册一次。
  void _ensureListening() {
    if (_onDirsChanged != null) return;
    final VoidCallback listener = invalidate;
    _onDirsChanged = listener;
    AppConfig.questionBankDirsNotifier.addListener(listener);
  }

  /// 只给测试用：清缓存并摘掉监听。
  static void resetForTest() {
    final BankRepository repo = instance;
    repo.invalidate();
    final VoidCallback? listener = repo._onDirsChanged;
    if (listener != null) {
      AppConfig.questionBankDirsNotifier.removeListener(listener);
      repo._onDirsChanged = null;
    }
  }
}

/// 在后台 isolate 里解析一份题库的统计。
///
/// 只读取 `stats` / `question` 字段，不构造完整 [QuestionBank]，减少
/// isolate 之间的数据拷贝。返回值必须是可跨 isolate 发送的普通 Map。
Map<String, dynamic> _parseBankAnalysis(String raw) {
  final Map<String, dynamic> empty = <String, dynamic>{
    'questionCount': 0,
    'practiceCount': 0,
    'attemptCount': 0,
    'wrongCount': 0,
    'wrongItems': <Map<String, dynamic>>[],
  };
  try {
    final dynamic decoded = jsonDecode(raw);
    if (decoded is! Map) return empty;
    final dynamic rawQuestions = decoded['questions'];
    if (rawQuestions is! List) return empty;

    int questionCount = 0;
    int attemptCount = 0;
    int wrongCount = 0;
    int? minAttempt;
    final List<Map<String, dynamic>> wrongItems = <Map<String, dynamic>>[];

    for (final dynamic item in rawQuestions) {
      if (item is! Map) continue;
      questionCount++;
      final dynamic stats = item['stats'];
      final int attempts = stats is Map && stats['attemptCount'] is num
          ? (stats['attemptCount'] as num).toInt()
          : 0;
      final int wrong = stats is Map && stats['wrongCount'] is num
          ? (stats['wrongCount'] as num).toInt()
          : 0;
      attemptCount += attempts;
      wrongCount += wrong;
      if (minAttempt == null || attempts < minAttempt) minAttempt = attempts;

      if (wrong > 0) {
        final String text = item['question']?.toString().trim() ?? '';
        if (text.isNotEmpty) {
          wrongItems.add(<String, dynamic>{'question': text, 'wrong': wrong});
        }
      }
    }

    wrongItems.sort(
      (Map<String, dynamic> a, Map<String, dynamic> b) =>
          (b['wrong'] as int).compareTo(a['wrong'] as int),
    );
    return <String, dynamic>{
      'questionCount': questionCount,
      'practiceCount': minAttempt ?? 0,
      'attemptCount': attemptCount,
      'wrongCount': wrongCount,
      // 每本保留前 20 条，统计页跨题库取前 5 足够。
      'wrongItems': wrongItems.take(20).toList(),
    };
  } catch (_) {
    return empty;
  }
}
