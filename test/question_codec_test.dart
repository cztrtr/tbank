import 'package:flutter_test/flutter_test.dart';
import 'package:tbank/models/question_bank.dart';

void main() {
  Question sampleQuestion() => Question(
    id: 'q_1',
    type: QuestionType.multipleChoice,
    question: '题干',
    image: 'a.png',
    options: const <QuestionOption>[
      QuestionOption(key: 'A', text: '甲'),
      QuestionOption(key: 'B', text: '乙'),
    ],
    correctAnswers: const <String>['A', 'B'],
    analysis: '解析',
    stats: QuestionStats(attemptCount: 3, wrongCount: 1),
    origin: 'q_src',
    mistakeScore: 2,
  );

  test('题库 JSON 往返不丢字段', () {
    final QuestionBank bank = QuestionBank(
      questions: <Question>[sampleQuestion()],
    );
    final QuestionBank decoded = QuestionCodec.decode(
      QuestionCodec.encode(bank),
    );
    final Question question = decoded.questions.single;

    expect(question.id, 'q_1');
    expect(question.type, QuestionType.multipleChoice);
    expect(question.question, '题干');
    expect(question.image, 'a.png');
    expect(
      question.options.map((QuestionOption option) => option.key),
      <String>['A', 'B'],
    );
    expect(question.correctAnswers, <String>['A', 'B']);
    expect(question.analysis, '解析');
    expect(question.stats.attemptCount, 3);
    expect(question.stats.wrongCount, 1);
    expect(question.origin, 'q_src');
    expect(question.mistakeScore, 2);
  });

  test('题库根 plugin 标记往返', () {
    final QuestionBank bank = QuestionBank(
      questions: <Question>[sampleQuestion()],
      plugin: 'coding',
      pluginVersion: 2,
    );
    final QuestionBank decoded = QuestionCodec.decode(
      QuestionCodec.encode(bank),
    );

    expect(decoded.plugin, 'coding');
    expect(decoded.pluginVersion, 2);
    expect(decoded.effectivePlugin, 'coding');
    expect(decoded.toJson().keys.first, 'plugin');
  });

  test('自定义插件题型保留原始 type 标识', () {
    final QuestionBank bank = QuestionBank(
      plugin: 'coding',
      questions: <Question>[
        Question(
          id: 'q_custom',
          type: QuestionType.fillBlank,
          typeId: 'coding',
          question: '写一个函数',
          options: const <QuestionOption>[],
          correctAnswers: const <String>['def f(): pass'],
          stats: QuestionStats(),
          pluginData: <String, dynamic>{
            'language': 'python',
            'code': 'def f(): pass',
          },
        ),
      ],
    );
    final Map<String, dynamic> encoded = bank.toJson();
    final QuestionBank decoded = QuestionCodec.bankFromJson(encoded);

    expect((encoded['questions'] as List).first['type'], 'coding');
    expect(decoded.questions.single.typeId, 'coding');
    expect(decoded.questions.single.type, QuestionType.fillBlank);
    expect(decoded.questions.single.pluginData, <String, dynamic>{
      'language': 'python',
      'code': 'def f(): pass',
    });
  });

  test('根节点不是对象时抛 FormatException', () {
    expect(() => QuestionCodec.decode('[]'), throwsFormatException);
  });

  test('未知题型按填空处理，缺字段不崩', () {
    final Question question = QuestionCodec.questionFromJson(<String, dynamic>{
      'id': 'x',
      'type': 'unknown',
    });

    expect(question.type, QuestionType.fillBlank);
    expect(question.options, isEmpty);
    expect(question.correctAnswers, isEmpty);
    expect(question.image, '');
    expect(question.analysis, '');
    expect(question.stats.attemptCount, 0);
    expect(question.stats.wrongCount, 0);
    expect(question.origin, isNull);
    expect(question.mistakeScore, isNull);
  });

  test('stats 字段类型不对时补 0', () {
    final Question question = QuestionCodec.questionFromJson(<String, dynamic>{
      'stats': <String, dynamic>{'attemptCount': '3', 'wrongCount': null},
    });

    expect(question.stats.attemptCount, 0);
    expect(question.stats.wrongCount, 0);
  });

  test('普通题不写错题本字段，image/analysis 始终写回', () {
    final Question question = QuestionCodec.questionFromJson(<String, dynamic>{
      'id': 'x',
      'type': 'single_choice',
      'question': '题',
      'options': <Map<String, String>>[
        <String, String>{'key': 'A', 'text': '甲'},
      ],
      'correctAnswer': <String>['A'],
    });

    final Map<String, dynamic> json = QuestionCodec.questionToJson(question);
    expect(json.containsKey('origin'), isFalse);
    expect(json.containsKey('mistakeScore'), isFalse);
    expect(json['image'], '');
    expect(json['analysis'], '');
    expect(json['stats'], <String, dynamic>{
      'attemptCount': 0,
      'wrongCount': 0,
    });
  });

  test('encodeQuestions 只输出 questions 数组', () {
    final Map<String, dynamic> decoded = QuestionCodec.decode(
      '{"questions":[]}',
    ).toJson();
    expect(decoded.keys, <String>['questions']);

    final String text = QuestionCodec.encodeQuestions(<Question>[
      sampleQuestion(),
    ]);
    expect(text.contains('"questions"'), isTrue);
    expect(text.contains('q_src'), isTrue);
  });
}
