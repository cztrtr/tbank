import 'package:flutter_test/flutter_test.dart';
import 'package:tbank/services/question_quality.dart';

Map<String, dynamic> _question({
  String type = 'single_choice',
  String question = '以下哪项正确？',
  String analysis = '正确答案是 A，其他选项与题干不符。',
  List<String> answers = const <String>['A'],
  List<Map<String, String>>? options,
}) {
  return <String, dynamic>{
    'type': type,
    'question': question,
    'analysis': analysis,
    'options':
        options ??
        <Map<String, String>>[
          <String, String>{'key': 'A', 'text': '正确项'},
          <String, String>{'key': 'B', 'text': '错误项'},
        ],
    'correctAnswer': answers,
  };
}

void main() {
  test('清理合法题并把选项和题干预处理', () {
    final QuestionQualityReport report = QuestionQualityReport();
    final List<Map<String, dynamic>> result = QuestionQuality.sanitizeBatch(
      questions: <Map<String, dynamic>>[
        _question(question: '  以下哪项正确？  '),
      ],
      seen: <String>{},
      report: report,
    );

    expect(result, hasLength(1));
    expect(result.single['question'], '以下哪项正确？');
    expect(report.accepted, 1);
    expect(report.removed, 0);
  });

  test('同类型重复题被去掉，不同类型同题干保留', () {
    final QuestionQualityReport report = QuestionQualityReport();
    final List<Map<String, dynamic>> result = QuestionQuality.sanitizeBatch(
      questions: <Map<String, dynamic>>[
        _question(),
        _question(),
        _question(type: 'true_false'),
      ],
      seen: <String>{},
      report: report,
    );

    expect(result, hasLength(2));
    expect(report.duplicates, 1);
    expect(report.accepted, 2);
  });

  test('空解析、空答案和答案不在选项中被过滤', () {
    final QuestionQualityReport report = QuestionQualityReport();
    final List<Map<String, dynamic>> result = QuestionQuality.sanitizeBatch(
      questions: <Map<String, dynamic>>[
        _question(analysis: '暂无解析'),
        _question(answers: <String>[]),
        _question(answers: <String>['C']),
        _question(type: 'multiple_choice', answers: <String>['A']),
        _question(
          options: <Map<String, String>>[
            <String, String>{'key': 'A', 'text': '重复'},
            <String, String>{'key': 'B', 'text': '重复'},
          ],
        ),
      ],
      seen: <String>{},
      report: report,
    );

    expect(result, isEmpty);
    expect(report.invalid, 5);
    expect(report.summary, contains('过滤 5 道'));
  });
}
