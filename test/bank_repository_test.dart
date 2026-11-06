import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:tbank/services/app_config.dart';
import 'package:tbank/services/bank_repository.dart';

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
    temp = await Directory.systemTemp.createTemp('tbank_repo_test_');
    sep = Platform.pathSeparator;
    PathProviderPlatform.instance = _FakePathProvider(temp.path);
    await Directory('${temp.path}${sep}docs').create(recursive: true);
    AppConfig.questionBankDirsNotifier.value = const <String>[];
    BankRepository.resetForTest();
  });

  tearDown(() async {
    BankRepository.resetForTest();
    try {
      if (await temp.exists()) await temp.delete(recursive: true);
    } on FileSystemException {
      // Windows 上偶尔还有句柄没释放，交给系统清理
    }
  });

  Future<File> writeJson(Directory dir, String name) async {
    await dir.create(recursive: true);
    final File file = File('${dir.path}$sep$name');
    await file.writeAsString(
      jsonEncode(<String, dynamic>{
        'questions': <Map<String, dynamic>>[
          <String, dynamic>{'id': 'Q001', 'type': 'fill_blank'},
        ],
      }),
    );
    return file;
  }

  test('合并用户目录和 AI 题库，并按 uri 去重', () async {
    final Directory userDir =
        Directory('${temp.path}$sep用户题库');
    await writeJson(userDir, 'a.json');
    await writeJson(userDir, 'b.json');

    final Directory aiDir =
        Directory('${temp.path}${sep}Question$sep主题');
    await writeJson(aiDir, 'ai.json');

    // 同一个目录加两次，扫描结果不能重复
    AppConfig.questionBankDirsNotifier.value = <String>[
      userDir.path,
      userDir.path,
    ];

    final BankScanResult result =
        await BankRepository.instance.listAll(refresh: true);

    expect(result.errors, isEmpty);
    expect(result.files, hasLength(3));
    expect(
      result.files.map((file) => file.name),
      containsAll(<String>['a.json', 'b.json', 'ai.json']),
    );
    // 结果只读，防止调用方误改缓存
    expect(
      () => result.files.add(result.files.first),
      throwsUnsupportedError,
    );
  });

  test('2 秒内复用缓存，refresh 强制重新扫描', () async {
    final Directory userDir = Directory('${temp.path}$sep缓存题库');
    await writeJson(userDir, 'a.json');
    AppConfig.questionBankDirsNotifier.value = <String>[userDir.path];

    final BankScanResult first =
        await BankRepository.instance.listAll(refresh: true);
    expect(first.files, hasLength(1));

    // 新增文件但走缓存：列表不变
    await writeJson(userDir, 'b.json');
    final BankScanResult cached =
        await BankRepository.instance.listAll();
    expect(cached.files, hasLength(1));

    // 强制刷新后才能看到新文件
    final BankScanResult refreshed =
        await BankRepository.instance.listAll(refresh: true);
    expect(refreshed.files, hasLength(2));
  });

  test('单个目录读取失败只记 errors，其它目录正常返回', () async {
    final Directory userDir = Directory('${temp.path}$sep正常题库');
    await writeJson(userDir, 'a.json');

    AppConfig.questionBankDirsNotifier.value = <String>[
      '${temp.path}$sep不存在的目录',
      userDir.path,
    ];

    final BankScanResult result =
        await BankRepository.instance.listAll(refresh: true);

    expect(result.errors, isNotEmpty);
    expect(result.files, hasLength(1));
    expect(result.files.single.name, 'a.json');
  });
}
