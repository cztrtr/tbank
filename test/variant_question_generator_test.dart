import 'package:flutter_test/flutter_test.dart';
import 'package:tbank/models/question_bank.dart';
import 'package:tbank/services/ai_question_generator.dart';
import 'package:tbank/services/variant_question_generator.dart';
import 'package:tbank/services/ds_api_service.dart';

/// AI 变式出题里可以脱离网络验证的纯逻辑。
void main() {
  group('VariantQuestionGenerator 命名', () {
    test('基名去掉 .json 后缀', () {
      expect(VariantQuestionGenerator.baseName('高数第一章.json'), '高数第一章');
      expect(VariantQuestionGenerator.baseName('Math.JSON'), 'Math');
      expect(VariantQuestionGenerator.baseName('题库'), '题库');
    });

    test('指定后缀生成文件名', () {
      expect(
        VariantQuestionGenerator.fileNameWithSuffix('高数第一章.json', 'beta'),
        '高数第一章-beta.json',
      );
    });

    test('希腊字母表是 24 个、按顺序首尾正确', () {
      expect(VariantQuestionGenerator.greekSuffixes.length, 24);
      expect(VariantQuestionGenerator.greekSuffixes.first, 'alpha');
      expect(VariantQuestionGenerator.greekSuffixes[1], 'beta');
      expect(VariantQuestionGenerator.greekSuffixes.last, 'omega');
    });

    test('按希腊字母顺序取第一个未占用的名字', () {
      String next(Set<String> used) =>
          VariantQuestionGenerator.pickNextFileName(
            sourceName: '题库.json',
            existingNames: used,
          );

      expect(next(<String>{}), '题库-alpha.json');
      expect(next(<String>{'题库-alpha.json'}), '题库-beta.json');
      expect(next(<String>{'题库-alpha.json', '题库-beta.json'}), '题库-gamma.json');
    });

    test('已占用判断不区分大小写', () {
      expect(
        VariantQuestionGenerator.pickNextFileName(
          sourceName: '题库.json',
          existingNames: <String>{'题库-ALPHA.JSON'},
        ),
        '题库-beta.json',
      );
    });

    test('跳过中间被删除的字母，不按数量推算', () {
      expect(
        VariantQuestionGenerator.pickNextFileName(
          sourceName: '题库.json',
          existingNames: <String>{'题库-alpha.json', '题库-gamma.json'},
        ),
        '题库-beta.json',
      );
    });

    test('24 个字母用完后接序号', () {
      final Set<String> used = <String>{
        for (final String suffix in VariantQuestionGenerator.greekSuffixes)
          '题库-$suffix.json',
      };
      expect(
        VariantQuestionGenerator.pickNextFileName(
          sourceName: '题库.json',
          existingNames: used,
        ),
        '题库-alpha-2.json',
      );
    });
  });

  group('题型标签', () {
    test('完整题型顺序', () {
      expect(AiQuestionGenerator.allTypeLabels, <String>[
        '单选',
        '多选',
        '判断',
        '填空',
        '名词解释',
        '解答',
        '证明',
      ]);
    });
  });

  group('VariantQuestionGenerator.typesOf', () {
    Question question(QuestionType type) => Question(
      id: 'q',
      type: type,
      question: '题干',
      options: const <QuestionOption>[],
      correctAnswers: const <String>['A'],
      stats: QuestionStats(),
    );

    test('按固定顺序去重', () {
      final QuestionBank bank = QuestionBank(
        questions: <Question>[
          question(QuestionType.fillBlank),
          question(QuestionType.singleChoice),
          question(QuestionType.singleChoice),
        ],
      );
      expect(VariantQuestionGenerator.typesOf(bank), <String>['单选', '填空']);
    });

    test('空题库返回空列表', () {
      expect(
        VariantQuestionGenerator.typesOf(
          QuestionBank(questions: const <Question>[]),
        ),
        isEmpty,
      );
    });
  });

  group('DsApiService.parseKnowledgePoints', () {
    test('解析带代码围栏的 JSON', () {
      final List<String> points = DsApiService.parseKnowledgePoints(
        '```json\n{"knowledgePoints":["牛顿第二定律","动量守恒"]}\n```',
      );
      expect(points, <String>['牛顿第二定律', '动量守恒']);
    });

    test('自动去掉重复知识点', () {
      final List<String> points = DsApiService.parseKnowledgePoints(
        '{"knowledgePoints":["洛伦兹力","洛伦兹力","电场强度"]}',
      );
      expect(points, <String>['洛伦兹力', '电场强度']);
    });

    test('空列表视为失败', () {
      expect(
        () => DsApiService.parseKnowledgePoints('{"knowledgePoints":[]}'),
        throwsA(isA<DsApiException>()),
      );
    });

    test('非法 JSON 抛 DsApiException', () {
      expect(
        () => DsApiService.parseKnowledgePoints('不是 JSON'),
        throwsA(isA<DsApiException>()),
      );
    });
  });
}
