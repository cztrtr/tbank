import 'package:flutter/foundation.dart';

import '../models/question_bank.dart';
import '../services/bank_io.dart';
import '../services/ds_api_service.dart';

/// 练习页的 AI 动作：读题目配图、主观题判分、生成解析。
///
/// 页面只负责 loading / 错误状态和界面；请求参数、配图读取都在这里，
/// 以后改提示词或加模型参数不用动页面。
class PracticeAiService {
  PracticeAiService._();

  /// 读题目配图；题目没图、目录未知或读取失败时返回 null。
  static Future<Uint8List?> questionImage(
    Question question,
    String? sourceDirectoryRef,
  ) async {
    if (!question.hasImage || sourceDirectoryRef == null) return null;

    try {
      return await BankIo.readSiblingBytes(
        sourceDirectoryRef,
        question.image,
      );
    } catch (error) {
      debugPrint('读取题目配图失败：$error');
      return null;
    }
  }

  /// 给主观题打分，返回 0-10。
  static Future<int> score(
    Question question, {
    required String answer,
    required List<Uint8List> answerImages,
    required String? sourceDirectoryRef,
  }) async {
    final Uint8List? imageBytes =
        await questionImage(question, sourceDirectoryRef);

    return DsApiService.scoreAnswer(
      question: question.question,
      standardAnswer: question.correctAnswers.join('\n'),
      userAnswer: answer,
      imageBytes: imageBytes,
      answerImages: answerImages,
    );
  }

  /// 通用 AI 补全；Prompt 由插件生成，App 只转发。
  static Future<String> complete({
    required String prompt,
    List<Uint8List> images = const <Uint8List>[],
  }) {
    return DsApiService.complete(prompt: prompt, images: images);
  }

  /// 生成题目解析；主观题带上作答文字和作答图片。
  static Future<String> explain(
    Question question, {
    required String correctAnswer,
    String? userAnswer,
    required List<Uint8List> answerImages,
    required String? sourceDirectoryRef,
  }) async {
    final Uint8List? imageBytes =
        await questionImage(question, sourceDirectoryRef);

    return DsApiService.explainQuestion(
      question: question.question,
      options: question.options
          .map((QuestionOption option) => '${option.key}. ${option.text}')
          .join('\n'),
      correctAnswer: correctAnswer,
      userAnswer: question.isFillBlank ? userAnswer : null,
      imageBytes: imageBytes,
      answerImages:
          question.isFillBlank ? answerImages : const <Uint8List>[],
    );
  }
}
