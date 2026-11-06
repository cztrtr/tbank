import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:tbank/models/question_bank_file.dart';
import 'package:tbank/screen/question_bank_page.dart';
import 'package:tbank/services/app_config.dart';

/// 把 App 私有目录固定到临时文件夹，方便在桌面测试。
class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.root);

  final String root;

  @override
  Future<String?> getApplicationSupportPath() async => root;
}

/// 写一个最小题库文件（管理页只看文件名，不解析内容）。
Future<void> _writeBank(String path) async {
  final File file = File(path);
  await file.parent.create(recursive: true);
  await file.writeAsString(
    jsonEncode(<String, dynamic>{'questions': <dynamic>[]}),
  );
}

/// 等页面里的真实文件 IO 走完。
Future<void> _drainIo(WidgetTester tester, {int rounds = 20}) async {
  for (int round = 0; round < rounds; round++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// 把页面滚到最底部，让懒加载的列表项构建出来。
Future<void> _scrollToBottom(WidgetTester tester) async {
  for (int i = 0; i < 6; i++) {
    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late String root;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('tbank_qbp_test_');
    PathProviderPlatform.instance = _FakePathProvider(temp.path);
    root = '${temp.path}${Platform.pathSeparator}题库根';
  });

  tearDown(() async {
    AppConfig.questionBankDirsNotifier.value = const <String>[];
    try {
      if (await temp.exists()) await temp.delete(recursive: true);
    } on FileSystemException {
      // Windows 上偶尔还有句柄没释放，交给系统清理
    }
  });

  testWidgets('管理页按「父文件夹 → 子文件夹 → 题库」三级展示', (WidgetTester tester) async {
    // 题库根/
    //   父A/子1/a.json
    //   父A/子2/b.json
    //   父B/c.json
    final String dirA1 =
        '$root${Platform.pathSeparator}父A'
        '${Platform.pathSeparator}子1';
    final String dirA2 =
        '$root${Platform.pathSeparator}父A'
        '${Platform.pathSeparator}子2';
    final String dirB = '$root${Platform.pathSeparator}父B';
    await tester.runAsync(() async {
      await _writeBank('$dirA1${Platform.pathSeparator}a.json');
      await _writeBank('$dirA2${Platform.pathSeparator}b.json');
      await _writeBank('$dirB${Platform.pathSeparator}c.json');
    });

    AppConfig.questionBankDirsNotifier.value = <String>[dirA1, dirA2, dirB];

    await tester.pumpWidget(
      MaterialApp(
        home: QuestionBankPage(onOpenBank: (QuestionBankFile file) {}),
      ),
    );
    await _drainIo(tester);
    await _scrollToBottom(tester);

    // 两个不同子目录共用一个父文件夹标题，且只出现一次
    expect(find.text('题库根'), findsOneWidget);
    expect(find.text('父A'), findsOneWidget);
    expect(find.text('子1'), findsOneWidget);
    expect(find.text('子2'), findsOneWidget);
    expect(find.text('父B'), findsOneWidget);

    // 文件按子文件夹归位
    expect(find.text('a'), findsOneWidget);
    expect(find.text('b'), findsOneWidget);
    expect(find.text('c'), findsOneWidget);

    // 每个目录保留自己的「移除目录」按钮，父标题上没有
    expect(find.byTooltip('移除该题库目录'), findsNWidgets(3));
  });
}
