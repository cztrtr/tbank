import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tbank/widgets/math_text.dart';

/// MathText 对「没包 $ 的裸 LaTeX」以及边界情况的容错。
void main() {
  Future<void> pumpText(WidgetTester tester, String text) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: MathText(text))));
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
}
