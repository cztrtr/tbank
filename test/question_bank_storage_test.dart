import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:tbank/models/question_bank_file.dart';
import 'package:tbank/services/question_bank_storage.dart';

/// 把 App 私有目录固定到临时文件夹，方便在桌面测试。
class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.root);

  final String root;

  @override
  Future<String?> getApplicationSupportPath() async => root;

  @override
  Future<String?> getApplicationDocumentsPath() async =>
      '$root${Platform.pathSeparator}docs';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late String sep;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('tbank_storage_test_');
    sep = Platform.pathSeparator;
    PathProviderPlatform.instance = _FakePathProvider(temp.path);
    // 工作副本写到 Documents 目录，真实环境里目录已存在
    await Directory('${temp.path}${sep}docs').create(recursive: true);
  });

  tearDown(() async {
    try {
      if (await temp.exists()) await temp.delete(recursive: true);
    } on FileSystemException {
      // Windows 上偶尔还有句柄没释放，交给系统清理
    }
  });

  QuestionBankFile fileFor(String dir, String name) => QuestionBankFile(
        name: name,
        uri: '$dir$sep$name',
        directoryRef: dir,
      );

  Future<void> writeBank(File file, String question, {int attempt = 0}) async {
    await file.parent.create(recursive: true);
    await file.writeAsString(
      jsonEncode(<String, dynamic>{
        'questions': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'Q001',
            'type': 'single_choice',
            'question': question,
            'options': <Map<String, String>>[
              <String, String>{'key': 'A', 'text': 'A'},
              <String, String>{'key': 'B', 'text': 'B'},
            ],
            'correctAnswer': <String>['A'],
            'stats': <String, int>{'attemptCount': attempt, 'wrongCount': 0},
          },
        ],
      }),
    );
  }

  Future<List<Directory>> workDirs() async {
    final Directory root =
        Directory('${temp.path}${sep}docs${sep}banks');
    if (!await root.exists()) return <Directory>[];
    final List<FileSystemEntity> entities = await root.list().toList();
    return entities.whereType<Directory>().toList();
  }

  Future<List<File>> dirtyFiles() async {
    final Directory root =
        Directory('${temp.path}${sep}docs${sep}banks');
    if (!await root.exists()) return <File>[];
    final List<FileSystemEntity> entities =
        await root.list(recursive: true).toList();
    return entities
        .whereType<File>()
        .where((File file) => file.path.endsWith('.dirty'))
        .toList();
  }

  test('不同目录的同名题库使用各自的工作副本', () async {
    final String dirA = '${temp.path}${sep}a';
    final String dirB = '${temp.path}${sep}b';
    await writeBank(File('$dirA$sep同名.json'), '来自 A');
    await writeBank(File('$dirB$sep同名.json'), '来自 B');

    final QuestionBankStorage storageA =
        QuestionBankStorage(file: fileFor(dirA, '同名.json'));
    final bankA = await storageA.load();
    expect(bankA.questions.single.question, '来自 A');

    bankA.questions.single.stats.attemptCount = 3;
    await storageA.save(bankA);
    expect(await storageA.syncBack(), isTrue);

    // 打开 B 不能影响 A 的副本
    final QuestionBankStorage storageB =
        QuestionBankStorage(file: fileFor(dirB, '同名.json'));
    final bankB = await storageB.load();
    expect(bankB.questions.single.question, '来自 B');

    // 再打开 A：读到的仍是 A 自己的内容与统计
    final bankA2 =
        await QuestionBankStorage(file: fileFor(dirA, '同名.json')).load();
    expect(bankA2.questions.single.question, '来自 A');
    expect(bankA2.questions.single.stats.attemptCount, 3);

    // 两个来源各有一个工作副本目录
    expect((await workDirs()).length, 2);
  });

  test('回拷失败时保留副本统计，并在下次加载时提示', () async {
    final String dir = '${temp.path}${sep}c';
    final File source = File('$dir$sep题库.json');
    await writeBank(source, '题干');

    final QuestionBankStorage storage =
        QuestionBankStorage(file: fileFor(dir, '题库.json'));
    final bank = await storage.load();
    bank.questions.single.stats.attemptCount = 9;
    await storage.save(bank);

    // 源目录被删：回拷必然失败
    await Directory(dir).delete(recursive: true);
    expect(await storage.syncBack(), isFalse);
    expect(await dirtyFiles(), isNotEmpty);

    // 下次加载：先补回拷（仍失败），退回读副本，统计不能丢
    final QuestionBankStorage reopened =
        QuestionBankStorage(file: fileFor(dir, '题库.json'));
    final bank2 = await reopened.load();
    expect(bank2.questions.single.stats.attemptCount, 9);
    expect(reopened.pendingSyncWarning, isNotNull);
  });

  test('回拷成功后清除标记，重新加载以源文件为准', () async {
    final String dir = '${temp.path}${sep}d';
    final File source = File('$dir$sep题库.json');
    await writeBank(source, '题干');

    final QuestionBankStorage storage =
        QuestionBankStorage(file: fileFor(dir, '题库.json'));
    final bank = await storage.load();
    bank.questions.single.stats.attemptCount = 7;
    await storage.save(bank);
    expect(await storage.syncBack(), isTrue);
    expect(await dirtyFiles(), isEmpty);

    final dynamic decoded =
        jsonDecode(await source.readAsString());
    final List<dynamic> questions =
        (decoded as Map<String, dynamic>)['questions'] as List<dynamic>;
    final Map<String, dynamic> stats =
        (questions.single as Map<String, dynamic>)['stats']
            as Map<String, dynamic>;
    expect(stats['attemptCount'], 7);

    final bank2 =
        await QuestionBankStorage(file: fileFor(dir, '题库.json')).load();
    expect(bank2.questions.single.stats.attemptCount, 7);
    expect(bank2.questions.single.question, '题干');
  });
}
