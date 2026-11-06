import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:tbank/models/question_bank_file.dart';
import 'package:tbank/services/practice_progress.dart';

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
  late QuestionBankFile file;
  const List<String> ids = <String>['q_1', 'q_2', 'q_3', 'q_4'];

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('tbank_progress_test_');
    sep = Platform.pathSeparator;
    PathProviderPlatform.instance = _FakePathProvider(temp.path);
    file = QuestionBankFile(
      name: '题库.json',
      uri: '${temp.path}$sep题库.json',
      directoryRef: temp.path,
    );
  });

  tearDown(() async {
    try {
      if (await temp.exists()) await temp.delete(recursive: true);
    } on FileSystemException {
      // Windows 上偶尔还有句柄没释放，交给系统清理
    }
  });

  test('保存后能按相同题目 id 恢复进度', () async {
    await PracticeProgress.save(
      file,
      PracticeProgress(
        index: 2,
        answeredCount: 3,
        correctCount: 2,
        answers: <int, ({bool correct, Set<String> selected})>{
          0: (correct: true, selected: <String>{'A'}),
          1: (correct: false, selected: <String>{'B'}),
        },
        questionIds: ids,
      ),
    );

    final PracticeProgress? loaded =
        await PracticeProgress.load(file, ids);
    expect(loaded, isNotNull);
    expect(loaded!.index, 2);
    expect(loaded.answeredCount, 3);
    expect(loaded.correctCount, 2);
    expect(loaded.answers[0]?.correct, isTrue);
    expect(loaded.answers[0]?.selected, <String>{'A'});
    expect(loaded.answers[1]?.correct, isFalse);
    expect(loaded.answers[1]?.selected, <String>{'B'});
  });

  test('题目 id 对不上时不恢复，避免判分结果错位', () async {
    await PracticeProgress.save(
      file,
      PracticeProgress(
        index: 1,
        answeredCount: 1,
        correctCount: 1,
        answers: <int, ({bool correct, Set<String> selected})>{},
        questionIds: ids,
      ),
    );

    expect(
      await PracticeProgress.load(file, <String>['q_1', 'q_2', 'q_3']),
      isNull,
    );
    expect(
      await PracticeProgress.load(file, <String>['q_1', 'q_2', 'q_3', 'q_9']),
      isNull,
    );
  });

  test('清除后不再恢复', () async {
    await PracticeProgress.save(
      file,
      PracticeProgress(
        index: 0,
        answeredCount: 0,
        correctCount: 0,
        answers: <int, ({bool correct, Set<String> selected})>{},
        questionIds: ids,
      ),
    );
    await PracticeProgress.clear(file);

    expect(await PracticeProgress.load(file, ids), isNull);
  });

  test('损坏的进度文件返回 null，不抛异常', () async {
    final Directory dir =
        Directory('${temp.path}${sep}progress');
    await dir.create(recursive: true);
    // 文件名与 PracticeProgress 的命名无关，这里直接找它写出的路径
    await PracticeProgress.save(
      file,
      PracticeProgress(
        index: 0,
        answeredCount: 0,
        correctCount: 0,
        answers: <int, ({bool correct, Set<String> selected})>{},
        questionIds: ids,
      ),
    );
    final List<FileSystemEntity> entities = await dir.list().toList();
    final List<File> files = entities.whereType<File>().toList();
    await files.single.writeAsString('不是 JSON');

    expect(await PracticeProgress.load(file, ids), isNull);
  });

  test('越界的题号被夹到有效范围', () async {
    await PracticeProgress.save(
      file,
      PracticeProgress(
        index: 99,
        answeredCount: 99,
        correctCount: 99,
        answers: <int, ({bool correct, Set<String> selected})>{},
        questionIds: ids,
      ),
    );

    final PracticeProgress? loaded =
        await PracticeProgress.load(file, ids);
    expect(loaded!.index, ids.length - 1);
    expect(loaded.answeredCount, ids.length);
    expect(loaded.correctCount, ids.length);
  });
}
