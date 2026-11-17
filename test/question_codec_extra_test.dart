import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tbank/models/question_bank.dart';

void main() {
  test('题库/题目里 App 不认识的字段会原样保留', () {
    final Map<String, dynamic> raw = <String, dynamic>{
      'plugin': 'standard',
      'title': '我的题库',
      'tags': <String>['期末', '重点'],
      'questions': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'Q001',
          'type': 'single_choice',
          'question': '题干',
          'options': <Map<String, String>>[
            <String, String>{'key': 'A', 'text': '甲'},
            <String, String>{'key': 'B', 'text': '乙'},
          ],
          'correctAnswer': <String>['A'],
          'stats': <String, int>{'attemptCount': 0, 'wrongCount': 0},
          // 用户手写的额外元数据。
          'difficulty': 'hard',
          'source': '课本 P12',
        },
      ],
    };

    final QuestionBank bank = QuestionCodec.decode(jsonEncode(raw));
    expect(bank.extra['title'], '我的题库');
    expect(bank.extra['tags'], <String>['期末', '重点']);
    expect(bank.questions.single.extra['difficulty'], 'hard');
    expect(bank.questions.single.extra['source'], '课本 P12');

    final Map<String, dynamic> encoded =
        jsonDecode(QuestionCodec.encode(bank)) as Map<String, dynamic>;
    expect(encoded['title'], '我的题库');
    expect(encoded['tags'], <String>['期末', '重点']);
    final Map<String, dynamic> question =
        (encoded['questions'] as List<dynamic>).single as Map<String, dynamic>;
    expect(question['difficulty'], 'hard');
    expect(question['source'], '课本 P12');
    // 已知字段仍然按最新值写回，不会被 extra 覆盖。
    expect(question['stats'], <String, dynamic>{
      'attemptCount': 0,
      'wrongCount': 0,
    });
  });

  test('未知字段不会影响 stats / image / analysis 的默认写回', () {
    final QuestionBank bank = QuestionCodec.decode(
      jsonEncode(<String, dynamic>{
        'questions': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'Q001',
            'type': 'fill_blank',
            'question': '题干',
            'correctAnswer': <String>['答案'],
            'customField': 1,
          },
        ],
      }),
    );
    final Map<String, dynamic> encoded =
        jsonDecode(QuestionCodec.encode(bank)) as Map<String, dynamic>;
    final Map<String, dynamic> question =
        (encoded['questions'] as List<dynamic>).single as Map<String, dynamic>;
    expect(question['image'], '');
    expect(question['analysis'], '');
    expect(question['customField'], 1);
  });
}
