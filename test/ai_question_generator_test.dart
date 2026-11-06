import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:tbank/services/ai_question_generator.dart';

import 'dart:io';

/// 把 App 私有目录固定到临时文件夹，方便在桌面测试。
class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.root);

  final String root;

  @override
  Future<String?> getApplicationSupportPath() async => root;
}

Map<String, dynamic> _question(String id) => <String, dynamic>{
  'id': id,
  'type': 'single_choice',
  'question': '题干 $id',
  'image': '',
  'options': <Map<String, dynamic>>[
    <String, dynamic>{'key': 'A', 'text': '选项 A'},
    <String, dynamic>{'key': 'B', 'text': '选项 B'},
  ],
  'correctAnswer': <String>['A'],
  'analysis': '',
  'stats': <String, dynamic>{'attemptCount': 0, 'wrongCount': 0},
};

String _join(String parent, String child) =>
    '$parent${Platform.pathSeparator}$child';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late String questionRoot;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('tbank_ai_question_test_');
    PathProviderPlatform.instance = _FakePathProvider(temp.path);
    questionRoot = _join(temp.path, 'Question');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  /// 在 `Question/<topic>[/<sub>]` 下放一个占位文件并返回路径。
  Future<File> touch(
    String topic,
    String name, {
    String? subTopic,
    String content = 'old',
  }) async {
    final String dir = subTopic == null
        ? _join(questionRoot, topic)
        : _join(_join(questionRoot, topic), subTopic);
    await Directory(dir).create(recursive: true);
    final File file = File(_join(dir, name));
    await file.writeAsString(content);
    return file;
  }

  group('reserveBaseName 预留基名', () {
    test('目录里没有同名文件时沿用用户填的名字', () async {
      final String base = await AiQuestionGenerator.reserveBaseName(
        topic: '拍书-高数',
        baseName: '期中卷',
      );
      expect(base, '期中卷');
      // 只算名字，不该创建目录
      expect(await Directory(_join(questionRoot, '拍书-高数')).exists(), isFalse);
    });

    test('同名文件已存在时依次追加 -2、-3', () async {
      await touch('拍书-高数', '期中卷.json');
      expect(
        await AiQuestionGenerator.reserveBaseName(
          topic: '拍书-高数',
          baseName: '期中卷',
        ),
        '期中卷-2',
      );

      await touch('拍书-高数', '期中卷-2.json');
      expect(
        await AiQuestionGenerator.reserveBaseName(
          topic: '拍书-高数',
          baseName: '期中卷',
        ),
        '期中卷-3',
      );
    });

    test('文件名留空时用「一级目录-时间戳」', () async {
      final String base = await AiQuestionGenerator.reserveBaseName(
        topic: '拍书-高数',
      );
      expect(base, startsWith('拍书-高数-'));
      expect(RegExp(r'^拍书-高数-\d{8}-\d{6}$').hasMatch(base), isTrue);
    });

    test('二级目录里的同名文件同样会避开', () async {
      await touch('拍书-高数', '期中卷.json', subTopic: '期中卷');
      expect(
        await AiQuestionGenerator.reserveBaseName(
          topic: '拍书-高数',
          subTopic: '期中卷',
          baseName: '期中卷',
        ),
        '期中卷-2',
      );
      // 一级目录里的同名文件不影响二级目录
      expect(
        await AiQuestionGenerator.reserveBaseName(
          topic: '另一个目录',
          subTopic: '期中卷',
          baseName: '期中卷',
        ),
        '期中卷',
      );
    });

    test('文件名里的非法字符被替换，避免出现路径分隔符', () async {
      final String base = await AiQuestionGenerator.reserveBaseName(
        topic: '拍书-高数',
        baseName: 'a/b:c*d',
      );
      expect(base, 'a_b_c_d');
    });
  });

  group('saveBatchTo 落盘不覆盖', () {
    test('同名文件已存在时写到 -2，旧内容原样保留', () async {
      final File old = await touch('拍书-高数', '期中卷.json', content: 'OLD');

      final AiBankInfo saved = await AiQuestionGenerator.saveBatchTo(
        topic: '拍书-高数',
        baseName: '期中卷',
        questions: <Map<String, dynamic>>[_question('Q001')],
        batchIndex: 1,
      );

      expect(saved.fileName, '期中卷-2.json');
      expect(await old.readAsString(), 'OLD');
      expect(await File(saved.path).exists(), isTrue);
    });

    test('多批生成时第二批追加 -2', () async {
      final AiBankInfo first = await AiQuestionGenerator.saveBatchTo(
        topic: '拍书-高数',
        baseName: '期中卷',
        questions: <Map<String, dynamic>>[_question('Q001')],
        batchIndex: 1,
      );
      final AiBankInfo second = await AiQuestionGenerator.saveBatchTo(
        topic: '拍书-高数',
        baseName: '期中卷',
        questions: <Map<String, dynamic>>[_question('Q002')],
        batchIndex: 2,
      );

      expect(first.fileName, '期中卷.json');
      expect(second.fileName, '期中卷-2.json');
      expect(await File(first.path).exists(), isTrue);
    });

    test('连续两轮都用预留基名时不会互相覆盖', () async {
      final String base1 = await AiQuestionGenerator.reserveBaseName(
        topic: '拍书-高数',
        baseName: '期中卷',
      );
      final AiBankInfo first = await AiQuestionGenerator.saveBatchTo(
        topic: '拍书-高数',
        baseName: base1,
        questions: <Map<String, dynamic>>[_question('Q001')],
        batchIndex: 1,
      );

      final String base2 = await AiQuestionGenerator.reserveBaseName(
        topic: '拍书-高数',
        baseName: '期中卷',
      );
      final AiBankInfo second = await AiQuestionGenerator.saveBatchTo(
        topic: '拍书-高数',
        baseName: base2,
        questions: <Map<String, dynamic>>[_question('Q001')],
        batchIndex: 1,
      );

      expect(first.fileName, '期中卷.json');
      expect(second.fileName, '期中卷-2.json');
      expect((await AiQuestionGenerator.listBanks()).length, 2);
    });
  });

  group('deleteBank 彻底删除', () {
    test('删除文件，并清理变空的二级 / 一级目录', () async {
      final File file = await touch('拍书-高数', '期中卷.json', subTopic: '期中卷');
      final AiBankInfo bank = AiBankInfo(
        topic: '拍书-高数/期中卷',
        fileName: '期中卷.json',
        path: file.path,
        questionCount: 1,
        modifiedAt: DateTime.now(),
      );

      await AiQuestionGenerator.deleteBank(bank);

      expect(await file.exists(), isFalse);
      expect(await Directory(_join(questionRoot, '拍书-高数')).exists(), isFalse);
      // 根目录始终保留
      expect(await Directory(questionRoot).exists(), isTrue);
    });

    test('目录里还有别的题库时不删目录', () async {
      final File target = await touch('拍书-高数', 'A.json');
      await touch('拍书-高数', 'B.json');

      await AiQuestionGenerator.deleteBank(
        AiBankInfo(
          topic: '拍书-高数',
          fileName: 'A.json',
          path: target.path,
          questionCount: 1,
          modifiedAt: DateTime.now(),
        ),
      );

      expect(await target.exists(), isFalse);
      final Directory dir = Directory(_join(questionRoot, '拍书-高数'));
      expect(await dir.exists(), isTrue);
      expect((await dir.list().toList()).length, 1);
    });

    test('文件本来就不存在时不抛异常', () async {
      await expectLater(
        AiQuestionGenerator.deleteBank(
          AiBankInfo(
            topic: '不存在',
            fileName: 'x.json',
            path: _join(questionRoot, '不存在/x.json'),
            questionCount: 0,
            modifiedAt: DateTime.now(),
          ),
        ),
        completes,
      );
    });

    test('删完后列表里不再出现该题库', () async {
      final AiBankInfo bank = await AiQuestionGenerator.saveBatchTo(
        topic: '拍书-高数',
        baseName: '期中卷',
        questions: <Map<String, dynamic>>[_question('Q001')],
        batchIndex: 1,
      );
      expect((await AiQuestionGenerator.listBanks()).length, 1);

      await AiQuestionGenerator.deleteBank(bank);
      expect(await AiQuestionGenerator.listBanks(), isEmpty);
    });
  });
}
