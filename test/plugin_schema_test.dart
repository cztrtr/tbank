import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tbank/services/ai_question_generator.dart';
import 'package:tbank/services/ds_api_service.dart';
import 'package:tbank/services/plugin_manager.dart';
import 'package:tbank/services/plugin_schema.dart';

void main() {
  final Map<String, dynamic> schema = <String, dynamic>{
    'type': 'object',
    'required': <String>['language', 'code'],
    'properties': <String, dynamic>{
      'language': <String, dynamic>{'type': 'string'},
      'code': <String, dynamic>{'type': 'string'},
    },
  };

  final PluginManifest plugin = PluginManifest(
    id: 'coding',
    name: '代码题',
    version: '1.0.0',
    apiVersion: 1,
    types: <String>['coding', 'code_review'],
    typeNames: <String, String>{'coding': '代码题', 'code_review': '代码审查'},
    typeDescriptions: <String, String>{'coding': '写代码', 'code_review': '审查代码'},
    typeSchemas: <String, Map<String, dynamic>>{
      'coding': schema,
      'code_review': schema,
    },
  );

  String rawFor(String type, {bool valid = true}) {
    return jsonEncode(<String, dynamic>{
      'questions': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'Q001',
          'type': type,
          'question': '题干',
          'options': <dynamic>[],
          'correctAnswer': <String>['answer'],
          'analysis': '',
          'stats': <String, dynamic>{'attemptCount': 0, 'wrongCount': 0},
          if (valid)
            'pluginData': <String, dynamic>{
              'language': 'dart',
              'code': 'void main() {}',
            },
        },
      ],
    });
  }

  test('schema 必填字段校验', () {
    expect(
      PluginSchemaValidator.validate(schema, <String, dynamic>{
        'language': 'dart',
        'code': 'x',
      }),
      isNull,
    );
    expect(
      PluginSchemaValidator.validate(schema, <String, dynamic>{
        'language': 'dart',
      }),
      contains('缺少必填字段 code'),
    );
  });

  test('generateWithCoverage 优先重试失败题并覆盖每个题型', () async {
    int calls = 0;
    final List<Map<String, dynamic>> questions =
        await AiQuestionGenerator.generateWithCoverage(
          plugin: plugin,
          types: plugin.typeInfos,
          target: 2,
          request: (PluginTypeInfo type, int count) async {
            calls++;
            // 第一次故意返回缺 pluginData 的坏题，验证立即重试。
            return rawFor(type.id, valid: calls != 1);
          },
        );

    expect(calls, 3);
    expect(questions.length, 2);
    expect(
      questions.map((Map<String, dynamic> q) => q['type']).toSet(),
      <String>{'coding', 'code_review'},
    );
    expect(
      questions.every((Map<String, dynamic> q) => q['pluginData'] is Map),
      isTrue,
    );
  });

  test('题量小于题型数时拒绝生成', () async {
    await expectLater(
      AiQuestionGenerator.generateWithCoverage(
        plugin: plugin,
        types: plugin.typeInfos,
        target: 1,
        request: (PluginTypeInfo type, int count) async => rawFor(type.id),
      ),
      throwsA(isA<DsApiException>()),
    );
  });
}
