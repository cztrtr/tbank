import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:tbank/services/app_config.dart';
import 'package:tbank/services/secret_store.dart';

/// 把 App 私有目录固定到临时文件夹。
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
  late String configPath;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('tbank_config_test_');
    PathProviderPlatform.instance = _FakePathProvider(temp.path);
    configPath = '${temp.path}${Platform.pathSeparator}config.json';
    AppConfig.resetForTest();
  });

  tearDown(() async {
    AppConfig.resetForTest();
    try {
      if (await temp.exists()) await temp.delete(recursive: true);
    } on FileSystemException {
      // Windows 上偶尔还有句柄没释放，交给系统清理。
    }
  });

  Future<void> writeConfig(Map<String, dynamic> data) async {
    await File(configPath).writeAsString(jsonEncode(data));
  }

  test('旧版 base64 Key 自动迁移到安全存储，并从 config.json 删除', () async {
    final MemorySecretStore store = MemorySecretStore();
    AppConfig.setSecretStoreForTest(store);
    await writeConfig(<String, dynamic>{
      'questionBankDirs': <String>['D:/题库'],
      'dsApiKey': base64Encode(utf8.encode('sk-legacy-1234567890')),
    });

    await AppConfig.init();

    expect(AppConfig.dsApiKey, 'sk-legacy-1234567890');
    expect(AppConfig.dsApiKeyStatus, DsApiKeyStatus.secure);
    expect(store.peek(SecretKeys.dsApiKey), 'sk-legacy-1234567890');

    final Map<String, dynamic> saved =
        jsonDecode(await File(configPath).readAsString())
            as Map<String, dynamic>;
    expect(saved.containsKey('dsApiKey'), isFalse);
    expect(saved['configVersion'], 2);
    expect(saved['dsApiKeyStorage'], 'secure');
    // 迁移完成后旧备份也要清掉，避免里面还留着 base64。
    expect(File('$configPath.bak').existsSync(), isFalse);
  });

  test('安全存储写入失败时保留旧 Key，并标记 legacyFallback', () async {
    final MemorySecretStore store = MemorySecretStore(failWrite: true);
    AppConfig.setSecretStoreForTest(store);
    await writeConfig(<String, dynamic>{
      'dsApiKey': base64Encode(utf8.encode('sk-legacy-1234567890')),
    });

    await AppConfig.init();

    expect(AppConfig.dsApiKey, 'sk-legacy-1234567890');
    expect(AppConfig.dsApiKeyStatus, DsApiKeyStatus.legacyFallback);
    expect(AppConfig.dsApiKeyWarning, isNotNull);

    final Map<String, dynamic> saved =
        jsonDecode(await File(configPath).readAsString())
            as Map<String, dynamic>;
    expect(saved['dsApiKey'], isNotNull);
  });

  test('安全存储不可用时，新 Key 保存失败且不会退回 base64', () async {
    final MemorySecretStore store = MemorySecretStore(failWrite: true);
    AppConfig.setSecretStoreForTest(store);

    await AppConfig.init();
    final bool saved = await AppConfig.setDsApiKey('sk-new-1234567890');

    expect(saved, isFalse);
    expect(AppConfig.dsApiKey, isNull);
    final Map<String, dynamic> data =
        jsonDecode(await File(configPath).readAsString())
            as Map<String, dynamic>;
    expect(data.containsKey('dsApiKey'), isFalse);
  });

  test('安全存储已配置时优先使用 secure 值，并清理 legacy', () async {
    final MemorySecretStore store = MemorySecretStore(
      initial: <String, String>{SecretKeys.dsApiKey: 'sk-secure-1234567890'},
    );
    AppConfig.setSecretStoreForTest(store);
    await writeConfig(<String, dynamic>{
      'dsApiKey': base64Encode(utf8.encode('sk-legacy-1234567890')),
    });

    await AppConfig.init();

    expect(AppConfig.dsApiKey, 'sk-secure-1234567890');
    expect(AppConfig.dsApiKeyStatus, DsApiKeyStatus.secure);
    final Map<String, dynamic> saved =
        jsonDecode(await File(configPath).readAsString())
            as Map<String, dynamic>;
    expect(saved.containsKey('dsApiKey'), isFalse);
  });

  test('清除 Key 时删除失败不假装成功', () async {
    final MemorySecretStore store = MemorySecretStore(
      initial: <String, String>{SecretKeys.dsApiKey: 'sk-secure-1234567890'},
      failDelete: true,
    );
    AppConfig.setSecretStoreForTest(store);
    await writeConfig(<String, dynamic>{'dsApiKeyStorage': 'secure'});

    await AppConfig.init();
    expect(AppConfig.dsApiKeyStatus, DsApiKeyStatus.secure);

    final bool cleared = await AppConfig.setDsApiKey(null);
    expect(cleared, isFalse);
    expect(AppConfig.dsApiKey, 'sk-secure-1234567890');

    store.failDelete = false;
    expect(await AppConfig.setDsApiKey(null), isTrue);
    expect(AppConfig.dsApiKey, isNull);
    expect(AppConfig.dsApiKeyStatus, DsApiKeyStatus.none);
  });

  test('config.json 损坏时从 .bak 恢复，并提示用户', () async {
    await File(configPath).writeAsString('{ 这不是 JSON');
    await File('$configPath.bak').writeAsString(
      jsonEncode(<String, dynamic>{'clockOnNum': 7}),
    );

    await AppConfig.init();

    expect(AppConfig.loadWarning, isNotNull);
    expect(AppConfig.clockOnNotifier.value, 7);
    // 恢复后主文件被重写为合法 JSON。
    final Map<String, dynamic> saved =
        jsonDecode(await File(configPath).readAsString())
            as Map<String, dynamic>;
    expect(saved['clockOnNum'], 7);
  });
}
