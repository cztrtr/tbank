import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:tbank/services/mistake_books.dart';

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
    temp = await Directory.systemTemp.createTemp('tbank_mistake_reset_');
    sep = Platform.pathSeparator;
    PathProviderPlatform.instance = _FakePathProvider(temp.path);
  });

  tearDown(() async {
    try {
      if (await temp.exists()) await temp.delete(recursive: true);
    } on FileSystemException {
      // Windows 上偶有句柄延迟释放，交给系统清理。
    }
  });

  test('重置错题本能删除嵌套分组目录和全部内容', () async {
    final Directory root = Directory(<String>[temp.path, 'mistakes'].join(sep));
    final Directory nested = Directory(
      <String>[root.path, '父组', '子组'].join(sep),
    );
    await nested.create(recursive: true);
    await File(<String>[nested.path, 'Alpha.json'].join(sep))
        .writeAsString('{}');
    await File(<String>[nested.path, 'C001.jpg'].join(sep))
        .writeAsBytes(<int>[1, 2, 3]);
    await File(<String>[root.path, 'deleted_origins.json'].join(sep))
        .writeAsString('[]');

    expect(await MistakeBooks.resetAll(), isTrue);
    expect(await root.exists(), isTrue);
    expect(await root.list().isEmpty, isTrue);
  });
}
