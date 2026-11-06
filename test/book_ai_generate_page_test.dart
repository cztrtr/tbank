import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:tbank/screen/book_ai_generate_page.dart';

/// 把 App 私有目录固定到临时文件夹，方便在桌面测试。
class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.root);

  final String root;

  @override
  Future<String?> getApplicationSupportPath() async => root;
}

/// 写一份最小的合法题库 JSON（放在测试 body 里时要包 [WidgetTester.runAsync]）。
Future<File> _writeBank(String path, {int count = 1}) async {
  final File file = File(path);
  await file.parent.create(recursive: true);
  await file.writeAsString(
    jsonEncode(<String, dynamic>{
      'questions': <Map<String, dynamic>>[
        for (int i = 1; i <= count; i++)
          <String, dynamic>{
            'id': 'Q${i.toString().padLeft(3, '0')}',
            'type': 'single_choice',
            'question': '题干 $i',
            'image': '',
            'options': <Map<String, dynamic>>[
              <String, dynamic>{'key': 'A', 'text': '选项 A'},
              <String, dynamic>{'key': 'B', 'text': '选项 B'},
            ],
            'correctAnswer': <String>['A'],
            'analysis': '',
            'stats': <String, dynamic>{'attemptCount': 0, 'wrongCount': 0},
          },
      ],
    }),
  );
  return file;
}

/// 等页面里的真实文件 IO 走完。
///
/// `testWidgets` 默认跑在 fake async 里，页面 initState / 删除里的
/// `dart:io` 调用不会自己完成；用 [WidgetTester.runAsync] 让真实事件循环转起来。
/// 这里按固定轮次推进，不依赖 finder —— 底部的转圈可能还没被 ListView 构建出来。
Future<void> _drainIo(WidgetTester tester, {int rounds = 20}) async {
  for (int round = 0; round < rounds; round++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// 把页面滚到最底部：列表在 ListView 里懒加载，不滚动的话底部内容不会构建。
Future<void> _scrollToBottom(WidgetTester tester) async {
  final Finder list = find.byType(ListView);
  for (int i = 0; i < 8; i++) {
    await tester.drag(list, const Offset(0, -600));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late String questionRoot;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('tbank_book_page_test_');
    PathProviderPlatform.instance = _FakePathProvider(temp.path);
    questionRoot = '${temp.path}${Platform.pathSeparator}Question';
  });

  tearDown(() async {
    // Windows 上偶尔还有文件句柄没释放，删不掉就交给系统临时目录清理
    try {
      if (await temp.exists()) await temp.delete(recursive: true);
    } on FileSystemException {
      // ignore
    }
  });

  testWidgets('已生成的题库会列出来，二次确认后彻底删除', (WidgetTester tester) async {
    final File bank = (await tester.runAsync(
      () => _writeBank(
        '$questionRoot${Platform.pathSeparator}拍书-高数'
        '${Platform.pathSeparator}期中卷.json',
        count: 3,
      ),
    ))!;

    await tester.pumpWidget(const MaterialApp(home: BookAiGeneratePage()));
    await _drainIo(tester);

    await _scrollToBottom(tester);

    // 目录分组 + 文件名 + 题数都在
    expect(find.text('拍书-高数'), findsOneWidget);
    expect(find.text('期中卷'), findsOneWidget);
    expect(find.textContaining('3 题'), findsOneWidget);

    final Finder deleteButton = find.byTooltip('彻底删除');
    expect(deleteButton, findsOneWidget);
    await tester.ensureVisible(deleteButton);
    await tester.tap(deleteButton);
    await tester.pumpAndSettle();

    // 弹确认框，且点「取消」不会删
    expect(find.text('彻底删除题库'), findsOneWidget);
    expect((await tester.runAsync(bank.exists))!, isTrue);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('彻底删除题库'), findsNothing);
    expect((await tester.runAsync(bank.exists))!, isTrue);

    // 确认后文件消失，列表回到空状态
    await tester.ensureVisible(deleteButton);
    await tester.tap(deleteButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await _drainIo(tester);

    expect((await tester.runAsync(bank.exists))!, isFalse);
    await _scrollToBottom(tester);
    expect(find.text('还没有生成过题库'), findsOneWidget);
  });

  testWidgets('二级目录的题库显示成「一级/二级」分组', (WidgetTester tester) async {
    await tester.runAsync(
      () => _writeBank(
        '$questionRoot${Platform.pathSeparator}拍书-高数'
        '${Platform.pathSeparator}期中卷${Platform.pathSeparator}卷A.json',
      ),
    );

    await tester.pumpWidget(const MaterialApp(home: BookAiGeneratePage()));
    await _drainIo(tester);
    await _scrollToBottom(tester);

    expect(find.text('拍书-高数/期中卷'), findsOneWidget);
    expect(find.text('卷A'), findsOneWidget);
  });
}
