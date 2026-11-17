import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tbank/services/atomic_write.dart';

void main() {
  test('写入时保留 .bak，读回备份可用', () async {
    final Directory dir = await Directory.systemTemp.createTemp(
      'tbank_atomic_test_',
    );
    final String path = '${dir.path}${Platform.pathSeparator}config.json';

    await AtomicWrite.writeText(path, '{"value":1}');
    expect(await File(path).readAsString(), '{"value":1}');
    expect(await File('$path.bak').exists(), isFalse);

    await AtomicWrite.writeText(path, '{"value":2}');
    expect(await File(path).readAsString(), '{"value":2}');
    expect(await File('$path.bak').readAsString(), '{"value":1}');
    expect((await AtomicWrite.readBackupText(path))!, '{"value":1}');

    await AtomicWrite.deleteBackup(path);
    expect(await File('$path.bak').exists(), isFalse);

    try {
      await dir.delete(recursive: true);
    } on FileSystemException {
      // Windows 句柄延迟释放，交给系统清理。
    }
  });

  test('读不到主文件时回退到备份', () async {
    final Directory dir = await Directory.systemTemp.createTemp(
      'tbank_atomic_test_',
    );
    final String path = '${dir.path}${Platform.pathSeparator}a.json';
    await File('$path.bak').writeAsString('{"from":"backup"}');

    final AtomicReadResult? result = await AtomicWrite.readTextWithBackup(path);
    expect(result, isNotNull);
    expect(result!.usedBackup, isTrue);
    expect(result.text, '{"from":"backup"}');

    try {
      await dir.delete(recursive: true);
    } on FileSystemException {
      // Windows 句柄延迟释放。
    }
  });
}
