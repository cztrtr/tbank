import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/question_bank_file.dart';
import 'ref_hash.dart';

/// 一次练习的断点：当前题号、本次计数、已答题的判分结果。
///
/// 只保存「已提交」的题目；未提交的输入和作答图片不落盘，
/// 避免把大块字节塞进进度文件。恢复时如果题库题目 id 对不上
/// （增删题、改顺序、换成同名文件），直接放弃这份进度。
class PracticeProgress {
  PracticeProgress({
    required this.index,
    required this.answeredCount,
    required this.correctCount,
    required this.answers,
    required this.questionIds,
  });

  /// 当前停在第几题（从 0 开始）。
  final int index;

  /// 本次练习已答题数。
  final int answeredCount;

  /// 本次练习答对题数。
  final int correctCount;

  /// 已答题的判分结果：题目下标 → (是否答对, 当时的选择)。
  final Map<int, ({bool correct, Set<String> selected})> answers;

  /// 保存时题库的题目 id 顺序；恢复前必须完全一致。
  final List<String> questionIds;

  /// 读取进度；文件不存在、损坏或题目对不上时返回 null。
  static Future<PracticeProgress?> load(
    QuestionBankFile file,
    List<String> questionIds,
  ) async {
    try {
      final File progressFile = await _fileFor(file);
      if (!await progressFile.exists()) return null;

      final dynamic decoded = jsonDecode(await progressFile.readAsString());
      if (decoded is! Map<String, dynamic>) return null;

      final dynamic rawIds = decoded['questionIds'];
      if (rawIds is! List) return null;
      final List<String> savedIds = rawIds.whereType<String>().toList();
      if (!listEquals(savedIds, questionIds)) return null;
      if (questionIds.isEmpty) return null;

      final Map<int, ({bool correct, Set<String> selected})> answers =
          <int, ({bool correct, Set<String> selected})>{};
      final dynamic rawAnswers = decoded['answers'];
      if (rawAnswers is Map) {
        rawAnswers.forEach((dynamic key, dynamic value) {
          final int? index = int.tryParse(key.toString());
          if (index == null || index < 0 || index >= questionIds.length) {
            return;
          }
          if (value is! Map) return;
          final dynamic selected = value['selected'];
          answers[index] = (
            correct: value['correct'] == true,
            selected: selected is List
                ? selected.whereType<String>().toSet()
                : <String>{},
          );
        });
      }

      final int rawIndex =
          decoded['index'] is num ? (decoded['index'] as num).toInt() : 0;
      final int safeIndex = rawIndex < 0
          ? 0
          : (rawIndex >= questionIds.length ? questionIds.length - 1 : rawIndex);

      final int rawAnswered = decoded['answeredCount'] is num
          ? (decoded['answeredCount'] as num).toInt()
          : answers.length;
      final int safeAnswered =
          rawAnswered.clamp(0, questionIds.length).toInt();

      final int rawCorrect = decoded['correctCount'] is num
          ? (decoded['correctCount'] as num).toInt()
          : answers.values.where((answer) => answer.correct).length;
      final int safeCorrect = rawCorrect.clamp(0, safeAnswered).toInt();

      return PracticeProgress(
        index: safeIndex,
        answeredCount: safeAnswered,
        correctCount: safeCorrect,
        answers: answers,
        questionIds: questionIds,
      );
    } catch (error) {
      // 进度文件损坏不应该挡住打开题库
      debugPrint('读取练习进度失败：$error');
      return null;
    }
  }

  /// 写入进度；失败只记日志，不影响答题。
  static Future<void> save(
    QuestionBankFile file,
    PracticeProgress progress,
  ) async {
    try {
      final File progressFile = await _fileFor(file);
      final Map<String, dynamic> json = <String, dynamic>{
        'index': progress.index,
        'answeredCount': progress.answeredCount,
        'correctCount': progress.correctCount,
        'questionIds': progress.questionIds,
        'answers': <String, dynamic>{
          for (final MapEntry<int, ({bool correct, Set<String> selected})> entry
              in progress.answers.entries)
            '${entry.key}': <String, dynamic>{
              'correct': entry.value.correct,
              'selected': entry.value.selected.toList()..sort(),
            },
        },
      };
      await progressFile.writeAsString(jsonEncode(json), flush: true);
    } catch (error) {
      debugPrint('保存练习进度失败：$error');
    }
  }

  /// 删除进度（重新开始、整套做完时调用）。
  static Future<void> clear(QuestionBankFile file) async {
    try {
      final File progressFile = await _fileFor(file);
      if (await progressFile.exists()) await progressFile.delete();
    } catch (error) {
      debugPrint('清除练习进度失败：$error');
    }
  }

  static Future<File> _fileFor(QuestionBankFile file) async {
    final Directory support = await getApplicationSupportDirectory();
    final Directory dir =
        Directory('${support.path}${Platform.pathSeparator}progress');
    if (!await dir.exists()) await dir.create(recursive: true);
    return File(
      '${dir.path}${Platform.pathSeparator}'
      '${stableRefHash(file.uri)}.json',
    );
  }
}
