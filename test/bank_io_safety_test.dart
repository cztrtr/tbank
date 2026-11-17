import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tbank/services/bank_io.dart';

void main() {
  test('safeSiblingName 拒绝路径穿越和子目录', () {
    expect(BankIo.safeSiblingName('q001.png'), 'q001.png');
    expect(BankIo.safeSiblingName(' 中文 图.webp '), '中文 图.webp');
    expect(BankIo.safeSiblingName(''), '');
    expect(BankIo.safeSiblingName('.'), '');
    expect(BankIo.safeSiblingName('..'), '');
    expect(BankIo.safeSiblingName('../secret.txt'), '');
    expect(BankIo.safeSiblingName('..\\secret.txt'), '');
    expect(BankIo.safeSiblingName('images/q001.png'), '');
    expect(BankIo.safeSiblingName('foo..bar.png'), '');
  });

  test('readSiblingBytes 不会读到题库目录之外的文件', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'tbank_path_test_',
    );
    final Directory bankDir = Directory('${root.path}/bank')..createSync();
    final File secret = File('${root.path}/secret.txt')
      ..writeAsStringSync('TOP SECRET');

    expect(
      await BankIo.readSiblingBytes(bankDir.path, '../secret.txt'),
      isNull,
    );
    expect(await BankIo.readSiblingBytes(bankDir.path, secret.path), isNull);

    final File image = File('${bankDir.path}/q.png')
      ..writeAsBytesSync(<int>[1, 2, 3]);
    expect(await BankIo.readSiblingBytes(bankDir.path, image.path), isNull);
    expect(
      await BankIo.readSiblingBytes(bankDir.path, 'q.png'),
      orderedEquals(<int>[1, 2, 3]),
    );

    try {
      await root.delete(recursive: true);
    } on FileSystemException {
      // Windows 句柄延迟释放，交给系统清理。
    }
  });
}
