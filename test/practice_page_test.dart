import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:tbank/models/question_bank_file.dart';
import 'package:tbank/screen/practice_page.dart';

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

/// 等页面里的真实文件 IO（复制题库、写工作副本）走完。
Future<void> _drainIo(WidgetTester tester, {int rounds = 50}) async {
  for (int round = 0; round < rounds; round++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// 构造一道单选题的 JSON。
Map<String, dynamic> _choiceQuestion(
  String id,
  String question,
  List<String> options,
  List<String> correctKeys,
) {
  return <String, dynamic>{
    'id': id,
    'type': 'single_choice',
    'question': question,
    'image': '',
    'options': <Map<String, String>>[
      for (int i = 0; i < options.length; i++)
        <String, String>{
          'key': String.fromCharCode(65 + i),
          'text': options[i],
        },
    ],
    'correctAnswer': correctKeys,
    'stats': <String, int>{'attemptCount': 0, 'wrongCount': 0},
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('tbank_practice_test_');
    PathProviderPlatform.instance = _FakePathProvider(temp.path);
    // 工作副本写到 Documents 目录，真实环境里目录已存在
    await Directory('${temp.path}${Platform.pathSeparator}docs')
        .create(recursive: true);
  });

  tearDown(() async {
    try {
      if (await temp.exists()) await temp.delete(recursive: true);
    } on FileSystemException {
      // Windows 上偶尔还有句柄没释放，交给系统清理
    }
  });

  testWidgets('填空/解答题答完后也有「AI 解析」按钮', (WidgetTester tester) async {
    final String sep = Platform.pathSeparator;
    final String bankDir = '${temp.path}$sep题库';
    final File bankFile = File('$bankDir$sep主观题.json');

    await tester.runAsync(() async {
      await Directory(bankDir).create(recursive: true);
      await bankFile.writeAsString(
        jsonEncode(<String, dynamic>{
          'questions': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'Q001',
              'type': 'fill_blank',
              'question': '测试题干',
              'image': '',
              'options': <dynamic>[],
              'correctAnswer': <String>['参考答案'],
              'analysis': '题库自带的解析。',
              'stats': <String, dynamic>{'attemptCount': 0, 'wrongCount': 0},
            },
          ],
        }),
      );
    });

    await tester.pumpWidget(
      MaterialApp(
        home: PracticePage(
          bank: QuestionBankFile(
            name: '主观题.json',
            uri: bankFile.path,
            directoryRef: bankDir,
            directoryName: '题库',
          ),
        ),
      ),
    );
    await _drainIo(tester);

    // 未配置 DeepSeek Key：走「展示答案 + 自判」流程
    expect(find.text('展示答案'), findsOneWidget);
    await tester.tap(find.text('展示答案'));
    await tester.pump();

    // 只要展示了参考答案，就应该能问 AI，不必先自判
    expect(find.text('AI 解析'), findsOneWidget);

    await tester.tap(find.text('答对了'));
    await _drainIo(tester);

    // 判分后按钮仍在，题库自带的解析照常显示
    expect(find.text('AI 解析'), findsOneWidget);
    expect(find.text('题库自带的解析。'), findsOneWidget);
  });

  testWidgets('退出后重进恢复上次练习进度', (WidgetTester tester) async {
    final String sep = Platform.pathSeparator;
    final String bankDir = '${temp.path}$sep题库2';
    final File bankFile = File('$bankDir$sep两题.json');

    await tester.runAsync(() async {
      await Directory(bankDir).create(recursive: true);
      await bankFile.writeAsString(
        jsonEncode(<String, dynamic>{
          'questions': <Map<String, dynamic>>[
            _choiceQuestion('Q001', '第一题', <String>['甲', '乙'], <String>['A']),
            _choiceQuestion('Q002', '第二题', <String>['丙', '丁'], <String>['A']),
          ],
        }),
      );
    });

    QuestionBankFile bank() => QuestionBankFile(
          name: '两题.json',
          uri: bankFile.path,
          directoryRef: bankDir,
          directoryName: '题库2',
        );

    await tester.pumpWidget(
      MaterialApp(home: PracticePage(bank: bank())),
    );
    await _drainIo(tester);

    // 第 1 题答对，切到第 2 题
    await tester.tap(find.text('甲'));
    await tester.pump();
    await tester.tap(find.text('提交答案'));
    await _drainIo(tester);
    expect(find.text('回答正确'), findsOneWidget);

    await tester.tap(find.text('下一题'));
    await _drainIo(tester);
    expect(find.textContaining('第 2 / 2 题'), findsOneWidget);

    // 卸载页面，模拟退出
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await _drainIo(tester);

    // 重新进入：停在第 2 题，并提示恢复了进度
    await tester.pumpWidget(
      MaterialApp(home: PracticePage(bank: bank())),
    );
    await _drainIo(tester);
    expect(find.textContaining('第 2 / 2 题'), findsOneWidget);
    expect(find.text('已恢复上次练习进度（第 2 题）'), findsOneWidget);

    // 回到第 1 题：判分结果也恢复了，可以继续看解析
    await tester.tap(find.text('上一题'));
    await _drainIo(tester);
    expect(find.text('回答正确'), findsOneWidget);
  });
}
