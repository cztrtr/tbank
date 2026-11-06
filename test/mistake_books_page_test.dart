import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:tbank/screen/mistake_books_page.dart';
import 'package:tbank/services/app_config.dart';

/// 把 App 私有目录固定到临时文件夹，方便在桌面测试。
class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.root);

  final String root;

  @override
  Future<String?> getApplicationSupportPath() async => root;
}

/// 等页面里的真实文件 IO（收集错题 + 扫描目录）走完。
Future<void> _drainIo(WidgetTester tester, {int rounds = 150}) async {
  for (int round = 0; round < rounds; round++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('tbank_mistake_page_test_');
    PathProviderPlatform.instance = _FakePathProvider(temp.path);
  });

  tearDown(() async {
    AppConfig.questionBankDirsNotifier.value = const <String>[];
    try {
      if (await temp.exists()) await temp.delete(recursive: true);
    } on FileSystemException {
      // Windows 上偶尔还有句柄没释放，交给系统清理
    }
  });

  testWidgets('错题本页按「父文件夹 → 题库子文件夹 → 错题本」展示', (WidgetTester tester) async {
    final String sep = Platform.pathSeparator;
    final String bankDir = '${temp.path}$sep题库根$sep父A$sep子1';
    final String mistakesDir = '${temp.path}${sep}mistakes';
    final String bookDir = '$mistakesDir$sep子1';

    await tester.runAsync(() async {
      // 一个有错题的本子，分组名就是题库文件夹名「子1」
      await Directory(bankDir).create(recursive: true);
      await File(
        '$bankDir${sep}a.json',
      ).writeAsString(jsonEncode(<String, dynamic>{'questions': <dynamic>[]}));
      await Directory(bookDir).create(recursive: true);
      await File('$bookDir${sep}Alpha.json').writeAsString(
        jsonEncode(<String, dynamic>{
          'questions': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'C001',
              'origin': 'q_stable_id',
              'mistakeScore': 3,
            },
          ],
        }),
      );
    });

    AppConfig.questionBankDirsNotifier.value = <String>[bankDir];

    await tester.pumpWidget(const MaterialApp(home: MistakeBooksPage()));
    await _drainIo(tester);

    expect(find.text('父A'), findsOneWidget, reason: '父文件夹标题');
    expect(find.text('子1'), findsOneWidget, reason: '题库子文件夹标题');
    expect(find.text('Alpha'), findsOneWidget, reason: '错题本');
  });
}
