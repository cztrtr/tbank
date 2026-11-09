import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:tbank/services/plugin_manager.dart';

/// 把 App 私有目录固定到临时文件夹，方便在桌面测试。
class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.root);

  final String root;

  @override
  Future<String?> getApplicationSupportPath() async => root;
}

Uint8List _zip(
  Map<String, dynamic> manifest, {
  String prefix = '',
  List<String> extraEntries = const <String>[],
}) {
  final Archive archive = Archive();
  final List<int> manifestBytes = utf8.encode(jsonEncode(manifest));
  archive.addFile(
    ArchiveFile('$prefix$manifestName', manifestBytes.length, manifestBytes),
  );
  for (final String name in extraEntries) {
    final List<int> bytes = utf8.encode('x');
    archive.addFile(ArchiveFile('$prefix$name', bytes.length, bytes));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

const String manifestName = 'manifest.json';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('tbank_plugin_test_');
    PathProviderPlatform.instance = _FakePathProvider(temp.path);
  });

  tearDown(() async {
    try {
      if (await temp.exists()) await temp.delete(recursive: true);
    } on FileSystemException {
      // Windows 上偶尔还有句柄没释放，交给系统清理
    }
  });

  Map<String, dynamic> manifest(String id, {List<String>? types}) {
    return <String, dynamic>{
      'id': id,
      'name': '测试插件',
      'version': '1.0.0',
      'apiVersion': 1,
      'types': types ?? <String>['single_choice'],
    };
  }

  test('安装 zip、写入目录并卸载', () async {
    final PluginManifest plugin = await PluginManager.importZipBytes(
      _zip(manifest('demo'), prefix: 'demo/'),
    );

    expect(plugin.id, 'demo');
    expect(plugin.builtin, isFalse);
    final Directory dir = await PluginManager.directory();
    final Directory installed = Directory(
      '${dir.path}${Platform.pathSeparator}demo',
    );
    expect(await installed.exists(), isTrue);
    expect(
      await File('${installed.path}${Platform.pathSeparator}$manifestName')
          .exists(),
      isTrue,
    );

    await PluginManager.uninstall('demo');
    expect(await installed.exists(), isFalse);
  });

  test('配置页和 config.json 按插件独立保存，升级保留', () async {
    await PluginManager.importZipBytes(
      _zip(manifest('demo'), extraEntries: <String>['config.html']),
    );

    expect(await PluginManager.configPageFile('demo'), isNotNull);
    expect(await PluginManager.readConfig('demo'), isEmpty);

    await PluginManager.writeConfig('demo', <String, dynamic>{
      'theme': 'dark',
      'limit': 3,
    });
    expect(await PluginManager.readConfig('demo'), <String, dynamic>{
      'theme': 'dark',
      'limit': 3,
    });

    // 升级插件：zip 里没有 config.json，旧配置不能被清掉
    await PluginManager.importZipBytes(
      _zip(manifest('demo'), extraEntries: <String>['config.html']),
    );
    expect(await PluginManager.readConfig('demo'), <String, dynamic>{
      'theme': 'dark',
      'limit': 3,
    });
  });

  test('内置 standard 不可覆盖、不可卸载', () async {
    expect(
      () => PluginManager.importZipBytes(_zip(manifest('standard'))),
      throwsA(isA<PluginException>()),
    );
    expect(
      () => PluginManager.uninstall('standard'),
      throwsA(isA<PluginException>()),
    );
  });

  test('非法路径、非法 id、缺少 types 都会被拒绝', () async {
    await expectLater(
      PluginManager.importZipBytes(_zip(manifest('evil'), prefix: '../')),
      throwsA(isA<PluginException>()),
    );
    await expectLater(
      PluginManager.importZipBytes(_zip(manifest('Bad Id'))),
      throwsA(isA<PluginException>()),
    );
    await expectLater(
      PluginManager.importZipBytes(_zip(manifest('demo', types: <String>[]))),
      throwsA(isA<PluginException>()),
    );
  });
}
