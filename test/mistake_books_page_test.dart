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

  testWidgets('子目录题库的错题本按「根目录 → 最后一级子目录」分级', (
    WidgetTester tester,
  ) async {
    final String sep = Platform.pathSeparator;
    final String bankDir = '${temp.path}$sep题库根$sep父A$sep子1';
    final String subDir = '$bankDir$sep线代';
    final String mistakesDir = '${temp.path}${sep}mistakes';
    final String bookDir = '$mistakesDir$sep子1$sep线代';

    await tester.runAsync(() async {
      await Directory(subDir).create(recursive: true);
      await File('$subDir${sep}b.json').writeAsString(
        jsonEncode(<String, dynamic>{
          'questions': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'Q001',
              'type': 'fill_blank',
              'question': '题',
              'options': <dynamic>[],
              'correctAnswer': <String>['答案'],
              'stats': <String, int>{'attemptCount': 1, 'wrongCount': 0},
            },
          ],
        }),
      );
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
    expect(find.text('子1'), findsOneWidget, reason: '添加的题库目录');
    expect(find.text('线代'), findsOneWidget, reason: '最后一级子目录');
    expect(find.text('子1/线代'), findsNothing, reason: '分组名不能拼成一行');
    expect(find.text('Alpha'), findsOneWidget, reason: '错题本');
  });

  testWidgets('同一根目录下的多个子目录只显示一次根目录标题', (
    WidgetTester tester,
  ) async {
    final String sep = Platform.pathSeparator;
    final String bankDir = '${temp.path}$sep题库根$sep父A$sep细胞生物学';
    final String sub1 = '$bankDir${sep}1_绪论';
    final String sub3 = '$bankDir${sep}3_细胞的类型';
    final String mistakesDir = '${temp.path}${sep}mistakes';

    await tester.runAsync(() async {
      await Directory(sub1).create(recursive: true);
      await Directory(sub3).create(recursive: true);
      final String emptyBank =
          jsonEncode(<String, dynamic>{'questions': <dynamic>[]});
      await File('$sub1${sep}a.json').writeAsString(emptyBank);
      await File('$sub3${sep}b.json').writeAsString(emptyBank);

      final String book1 = '$mistakesDir$sep细胞生物学${sep}1_绪论';
      final String book3 = '$mistakesDir$sep细胞生物学${sep}3_细胞的类型';
      await Directory(book1).create(recursive: true);
      await Directory(book3).create(recursive: true);
      await File('$book1${sep}Alpha.json').writeAsString(
        jsonEncode(<String, dynamic>{
          'questions': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'C001',
              'origin': 'q_a',
              'mistakeScore': 3,
            },
          ],
        }),
      );
      await File('$book3${sep}Beta.json').writeAsString(
        jsonEncode(<String, dynamic>{
          'questions': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'C001',
              'origin': 'q_b',
              'mistakeScore': 3,
            },
          ],
        }),
      );
    });

    AppConfig.questionBankDirsNotifier.value = <String>[bankDir];

    await tester.pumpWidget(const MaterialApp(home: MistakeBooksPage()));
    await _drainIo(tester);

    expect(find.text('父A'), findsOneWidget);
    expect(find.text('细胞生物学'), findsOneWidget, reason: '根目录标题只显示一次');
    expect(find.text('1_绪论'), findsOneWidget);
    expect(find.text('3_细胞的类型'), findsOneWidget);
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsOneWidget);
  });
}
