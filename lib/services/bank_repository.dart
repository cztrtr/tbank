import 'dart:async';

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
class BankRepository {
  BankRepository._();

  static final BankRepository instance = BankRepository._();

  static const Duration _cacheTtl = Duration(seconds: 2);

  BankScanResult? _cached;
  DateTime? _cachedAt;
  Future<BankScanResult>? _inflight;
  VoidCallback? _onDirsChanged;

  /// 丢弃缓存；题库目录增删后由监听器自动调用。
  void invalidate() {
    _cached = null;
    _cachedAt = null;
    _inflight = null;
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
      future.then<void>(
        (BankScanResult result) {
          _cached = result;
          _cachedAt = DateTime.now();
        },
        onError: (Object error, StackTrace stack) {
          // _scan 自己吞掉了目录异常，这里只防御未预料的错误
          debugPrint('扫描题库失败：$error');
        },
      ).whenComplete(() {
        if (identical(_inflight, future)) _inflight = null;
      }),
    );
    return future;
  }

  Future<BankScanResult> _scan() async {
    // 从全局 notifier 取最新目录，保证加号新增的目录立即可见
    final List<String> dirs = List<String>.of(
      AppConfig.questionBankDirsNotifier.value,
    );
    final List<QuestionBankFile> files = <QuestionBankFile>[];
    final List<String> errors = <String>[];
    final Set<String> seen = <String>{};

    // 用户添加的目录并发扫描：单个目录失败只记错误，不影响其它目录
    final List<({List<QuestionBankFile> files, String? error})> results =
        await Future.wait(
      dirs.map((String dirRef) async {
        try {
          final List<QuestionBankFile> found = await BankIo.listJsonFiles(
            dirRef,
            directoryName: BankIo.displayNameOf(dirRef),
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
        if (seen.add(file.uri)) files.add(file);
      }
    }

    // App 内置的 AI 题库（含拍书出题的二级目录）也显示在列表里
    try {
      for (final QuestionBankFile file
          in await AiQuestionGenerator.listBankFiles()) {
        if (seen.add(file.uri)) files.add(file);
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
