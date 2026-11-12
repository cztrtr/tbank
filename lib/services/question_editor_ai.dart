// 题目编辑器的 AI 能力：重新出题 / 纠正错误。
//
// 只负责「构造提示词 → 调用模型 → 解析回一道题」，不碰界面和文件；
// 编辑页拿到结果后自己替换题目并落盘。
import 'dart:convert';

import '../models/question_bank.dart';
import 'ai_question_generator.dart';
import 'ds_api_service.dart';

/// 「重新出题」「纠正错误」两个动作的模型侧实现。
class QuestionEditorAi {
  QuestionEditorAi._();

  /// 让 AI 重写（`fix == false`）或核对修正（`fix == true`）一道题。
  ///
  /// [guidance] 是用户填的方向 / 重点，非空时追加进提示词，让模型按这个方向改；
  /// 留空就按默认要求处理。
  ///
  /// 返回规范化后的单题 JSON（字段与题库格式一致）；模型没给出可用题目时
  /// 抛 [DsApiException]，由页面显示原因。
  static Future<Map<String, dynamic>> rewrite(
    Question question, {
    required String topic,
    bool fix = false,
    String guidance = '',
  }) async {
    final String prompt = _buildPrompt(
      question,
      topic: topic,
      fix: fix,
      guidance: guidance,
    );
    final String raw = await DsApiService.complete(prompt: prompt);

    // 复用出题器的解析器：容错 JSON 围栏、缺字段、答案不在选项里等情况。
    // 只放行原题的题型，避免 AI 顺手换了题型把题目弄坏。
    final List<Map<String, dynamic>> parsed =
        AiQuestionGenerator.parseQuestions(
          raw,
          allowedTypes: <String>{question.typeId},
        );
    if (parsed.isEmpty) {
      throw DsApiException('AI 没有返回可用的题目，请重试');
    }
    return parsed.first;
  }

  /// 拼提示词：把原题整段贴进去，让模型有足够的上下文。
  static String _buildPrompt(
    Question question, {
    required String topic,
    required bool fix,
    String guidance = '',
  }) {
    final Map<String, dynamic> source = <String, dynamic>{
      'type': question.typeId,
      'question': question.question,
      'options': question.options
          .map(
            (QuestionOption option) => <String, String>{
              'key': option.key,
              'text': option.text,
            },
          )
          .toList(),
      'correctAnswer': question.correctAnswers,
      'analysis': question.analysis,
    };

    final StringBuffer buffer = StringBuffer();
    if (fix) {
      buffer.writeln('你是严谨的审题编辑。下面这道题的答案或解析可能有错误，请核对后输出修正版本。');
      buffer.writeln();
      buffer.writeln('要求：');
      buffer.writeln('- 题干保留原意，只修正表述、符号或明显的笔误；');
      buffer.writeln('- 选项尽量保留，确有必要才调整措辞；');
      buffer.writeln('- 正确答案必须自洽：选择题的答案必须落在选项 key 里；');
      buffer.writeln('- 解析要写清关键步骤和判断依据，控制在 200 字以内；');
      buffer.writeln('- 如果原题没有错误，按原样返回即可。');
    } else {
      buffer.writeln(
        '你是出题老师。下面这道题来自题库「$topic」，'
        '请围绕同样的知识点重新出一道不同的新题。',
      );
      buffer.writeln();
      buffer.writeln('要求：');
      buffer.writeln('- 题型必须保持 ${question.typeId} 不变；');
      buffer.writeln('- 难度相当，但不能和原题重复（换情境、换数值或换问法）；');
      buffer.writeln('- 原题的选项数量保持不变（选择题）；');
      buffer.writeln('- 必须给出正确答案，选择题的答案必须落在选项 key 里；');
      buffer.writeln('- 附上清晰、能自学的解析。');
    }
    buffer.writeln('- 数学表达式用 LaTeX：行内用 \$...\$，独立公式用 \$\$...\$\$，'
        '不要裸写 \\frac、\\sqrt 等命令；');
    buffer.writeln('- 只输出 JSON，不要任何解释文字，也不要用 Markdown 围栏。');

    // 用户填的方向 / 重点：放在硬性约束之后，作为可覆盖的偏好
    final String extra = guidance.trim();
    if (extra.isNotEmpty) {
      buffer.writeln();
      buffer.writeln('用户的额外要求（优先满足，但不能违反上面的题型和格式约束）：');
      buffer.writeln(extra);
    }

    buffer.writeln();
    buffer.writeln('输出格式：');
    buffer.writeln(
      '{"questions":[{"type":"${question.typeId}","question":"题干",'
      '"options":[{"key":"A","text":"选项"}],'
      '"correctAnswer":["A"],"analysis":"解析"}]}',
    );
    if (question.isFillBlank) {
      buffer.writeln('（填空 / 主观题把 options 写成空数组，'
          'correctAnswer 直接写答案文本。）');
    }
    buffer.writeln();
    buffer.writeln('原题：');
    buffer.writeln(const JsonEncoder.withIndent('  ').convert(source));
    return buffer.toString();
  }
}
