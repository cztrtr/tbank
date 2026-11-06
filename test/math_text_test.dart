import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tbank/widgets/math_text.dart';

/// MathText 对「没包 $ 的裸 LaTeX」以及边界情况的容错。
void main() {
  Future<void> pumpText(
    WidgetTester tester,
    String text, {
    int? maxLines,
    TextOverflow? overflow,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MathText(text, maxLines: maxLines, overflow: overflow),
        ),
      ),
    );
  }

  testWidgets('裸写的 \\frac 也能渲染', (WidgetTester tester) async {
    await pumpText(tester, r'由 \frac{1}{2} 可知');
    expect(find.byType(Math), findsOneWidget);
    // 没有走后路的原文显示
    expect(find.text(r'\frac{1}{2}'), findsNothing);
  });

  testWidgets('多转义一层的 \\\\frac 也能渲染', (WidgetTester tester) async {
    await pumpText(tester, r'答案是 $\\frac{1}{2}$');
    expect(find.byType(Math), findsOneWidget);
  });

  testWidgets('裸写 \\(\\sqrt{2}\\) 也能渲染', (WidgetTester tester) async {
    await pumpText(tester, r'边长是 \sqrt{2} 米');
    expect(find.byType(Math), findsOneWidget);
  });

  testWidgets('普通美元金额不被当成公式', (WidgetTester tester) async {
    await pumpText(tester, r'价格是 $5 到 $10');
    expect(find.byType(Math), findsNothing);
    expect(find.text(r'价格是 $5 到 $10'), findsOneWidget);
  });

  testWidgets('公式里含中文但有数学结构时仍然渲染', (WidgetTester tester) async {
    await pumpText(tester, r'当 $\text{当 } x>0$ 时');
    expect(find.byType(Math), findsOneWidget);
  });

  testWidgets('Windows 路径不会误判成公式', (WidgetTester tester) async {
    await pumpText(tester, r'路径 C:\Users\test');
    expect(find.byType(Math), findsNothing);
  });

  testWidgets('正常 \$ 包裹的公式不受影响', (WidgetTester tester) async {
    await pumpText(tester, r'所以 $x^2 + 1 = 0$ 成立');
    expect(find.byType(Math), findsOneWidget);
  });

  testWidgets('限定 maxLines 时块级公式与正文合并成一段', (WidgetTester tester) async {
    await pumpText(
      tester,
      r'已知 $$\frac{1}{2}$$ 和 $x^2$ 的关系',
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );

    // 统计页这类摘要要求整段截断：不应再拆成多个段落
    final Iterable<RichText> texts = tester.widgetList<RichText>(
      find.byType(RichText),
    );
    final RichText rich = texts.firstWhere(
      (RichText w) => w.maxLines == 2,
      orElse: () => throw StateError('没有带 maxLines 的 RichText'),
    );
    expect(rich.overflow, TextOverflow.ellipsis);
    expect(find.byType(Math), findsNWidgets(2));
  });

  testWidgets('没有公式的纯文本同样遵守 maxLines', (WidgetTester tester) async {
    await pumpText(
      tester,
      '这道题的题干很长很长，长到需要截断才能放进统计卡片里',
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );

    final Text text = tester.widget<Text>(
      find.text('这道题的题干很长很长，长到需要截断才能放进统计卡片里'),
    );
    expect(text.maxLines, 2);
    expect(text.overflow, TextOverflow.ellipsis);
  });
}
