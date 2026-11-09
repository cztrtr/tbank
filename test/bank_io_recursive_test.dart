import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tbank/models/question_bank_file.dart';
import 'package:tbank/services/bank_io.dart';

void main() {
  late Directory temp;
  late Directory root;
  late String sep;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('tbank_recursive_test_');
    sep = Platform.pathSeparator;
    root = Directory('${temp.path}$sep高数');
    await root.create(recursive: true);

    // 根目录文件
    await File('${root.path}$sep根题库.json').writeAsString('{}');

    // 一层子目录
    final Directory sub = Directory('${root.path}$sep线代');
    await sub.create(recursive: true);
    await File('${sub.path}$sep第一章.json').writeAsString('{}');

    // 二层子目录：只递归一层，不应被扫到
    final Directory deep = Directory('${sub.path}$sep更深');
    await deep.create(recursive: true);
    await File('${deep.path}$sep第二章.json').writeAsString('{}');

    // 隐藏目录：不应被扫到
    final Directory hidden = Directory('${root.path}$sep.hidden');
    await hidden.create(recursive: true);
    await File('${hidden.path}$sep隐藏.json').writeAsString('{}');
  });

  tearDown(() async {
    try {
      if (await temp.exists()) await temp.delete(recursive: true);
    } on FileSystemException {
      // Windows 上偶尔还有句柄没释放，交给系统清理
    }
  });

  test('recursive=false 只扫根目录', () async {
    final List<QuestionBankFile> files =
        await BankIo.listJsonFiles(root.path);

    expect(files.map((QuestionBankFile file) => file.name), <String>['根题库.json']);
    expect(files.single.subDirectory, '');
    expect(files.single.sourceDirectoryRef, root.path);
  });

  test('recursive=true 扫根目录和一层子目录，跳过更深与隐藏目录', () async {
    final List<QuestionBankFile> files = await BankIo.listJsonFiles(
      root.path,
      directoryName: '高数',
      recursive: true,
    );

    final List<String> names =
        files.map((QuestionBankFile file) => file.displayPath).toList();
    expect(names, containsAll(<String>['根题库', '线代/第一章']));
    expect(names.any((String name) => name.contains('更深')), isFalse);
    expect(names.any((String name) => name.contains('隐藏')), isFalse);

    final QuestionBankFile subFile = files.firstWhere(
      (QuestionBankFile file) => file.subDirectory == '线代',
    );
    expect(subFile.directoryRef, '${root.path}$sep线代');
    expect(subFile.sourceDirectoryRef, root.path);
    expect(subFile.rootDirectoryRef, root.path);
    expect(subFile.directoryName, '高数/线代');

    final QuestionBankFile rootFile = files.firstWhere(
      (QuestionBankFile file) => file.subDirectory.isEmpty,
    );
    expect(rootFile.directoryRef, root.path);
    expect(rootFile.directoryName, '高数');
    expect(rootFile.displayPath, '根题库');
  });
}
