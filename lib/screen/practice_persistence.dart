import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/question_bank.dart';
import '../models/question_bank_file.dart';
import '../services/practice_progress.dart';
import '../services/question_bank_storage.dart';

/// 练习页的持久化：工作副本保存、防抖、回拷和断点。
///
/// 从 PracticePage 里抽出来以后，页面只负责 UI、判分和 AI 状态；
/// 保存顺序、400ms 防抖、错题本每题回写、断点清理都在这里，
/// 可以单独测试，也不会被页面的 setState 牵连。
class PracticePersistence {
  PracticePersistence({required this.file});

  final QuestionBankFile file;

  QuestionBankStorage? _storage;
  QuestionBank? _lastBank;
  Timer? _timer;
  bool _pending = false;

  static const Duration _debounce = Duration(milliseconds: 400);

  QuestionBankStorage? get storage => _storage;

  /// 题库所在目录：题目配图从这里读。
  String get sourceDirectoryRef =>
      _storage?.sourceDirectoryRef ?? file.directoryRef;

  /// 绑定当前题库的读写器（换题库时新建一个 persistence）。
  void bind(QuestionBankStorage storage) {
    _storage = storage;
  }

  /// 安排一次防抖保存；400ms 内的连续操作合并成一次写盘。
  void scheduleSave(QuestionBank bank) {
    _lastBank = bank;
    _pending = true;
    _timer?.cancel();
    _timer = Timer(_debounce, () {
      _timer = null;
      unawaited(flush());
    });
  }

  /// 立即把待保存内容写进工作副本；没有待保存任务时直接返回。
  Future<void> flush() async {
    _timer?.cancel();
    _timer = null;
    if (!_pending) return;
    _pending = false;
    await saveNow();
  }

  /// 把内存中的题库写回文档目录下的工作副本。
  ///
  /// 错题本的源文件就在 App 私有目录，写入成本极低，所以每题顺便回拷；
  /// 普通题库只在完成/后台/离开页面时回拷。
  Future<void> saveNow() async {
    final QuestionBankStorage? storage = _storage;
    final QuestionBank? bank = _lastBank;
    if (storage == null || bank == null) return;

    try {
      await storage.save(bank);
      if (bank.questions.any((Question question) => question.isFromMistakeBook)) {
        await storage.syncBack();
      }
    } catch (error) {
      debugPrint('保存工作副本失败：$error');
    }
  }

  /// 把工作副本回拷到题库文件夹。
  Future<bool> syncBack() async {
    final QuestionBankStorage? storage = _storage;
    if (storage == null) return false;

    try {
      return await storage.syncBack();
    } catch (error) {
      debugPrint('同步回题库文件夹失败：$error');
      return false;
    }
  }

  /// 保存断点：题目 id 顺序、当前题号、本次计数和已答结果。
  ///
  /// 整套做完后由调用方清除；题库还没加载完时什么都不做。
  Future<void> saveProgress({
    required QuestionBank bank,
    required int index,
    required int answeredCount,
    required int correctCount,
    required Map<int, ({bool correct, Set<String> selected})> answers,
  }) {
    return PracticeProgress.save(
      file,
      PracticeProgress(
        index: index,
        answeredCount: answeredCount,
        correctCount: correctCount,
        answers: Map<int, ({bool correct, Set<String> selected})>.of(answers),
        questionIds:
            bank.questions.map((Question question) => question.id).toList(),
      ),
    );
  }

  /// 整套做完或重新开始时删除断点。
  Future<void> clearProgress() => PracticeProgress.clear(file);

  /// 页面销毁时取消计时器；待保存内容由调用方先 flush。
  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}
