import 'package:flutter/material.dart';

import 'screen/main_screen.dart';
import 'services/app_config.dart';
import 'services/mistake_books.dart';

/// 应用入口。
///
/// 顺序很重要：
/// 1. 初始化 Flutter 绑定，之后才能使用 path_provider 等插件；
/// 2. 等待配置加载完成，界面里才能同步读取 AppConfig；
/// 3. 自动把已添加题库的题目 id 迁移成稳定随机 id（幂等，已迁移的跳过）；
/// 4. 启动界面。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized(); // path_provider 依赖平台通道，必须先初始化绑定
  await AppConfig.init(); // 读配置：有文件就解析，没有就创建，内容进内存

  // 启动时自动迁移：把已添加题库里的题目 id 换成稳定随机 id，
  // 让错题去重与文件位置彻底解耦。幂等，已迁移过的文件不会重写。
  await MistakeBooks.migrateAllBankIds();

  runApp(const MainApp()); // 配置就绪后再启动界面
}

/// 应用根组件：配置主题和首页。
///
/// 主题用 Material 3 + 种子色同时生成亮色和暗色方案，
/// 底栏、AppBar、卡片的样式都集中在这里，页面里尽量只用 colorScheme。
class MainApp extends StatelessWidget {
  const MainApp({super.key});

  static const Color _seedColor = Color(0xFF2F6FED);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TBank',
      debugShowCheckedModeBanner: false,
      theme: _buildTheme(Brightness.light),
      darkTheme: _buildTheme(Brightness.dark),
      home: const MainScreen(),
    );
  }

  /// 根据亮度构造主题；亮色和暗色只差一个 Brightness。
  ThemeData _buildTheme(Brightness brightness) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: _seedColor,
      brightness: brightness,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: colorScheme.surface,
      appBarTheme: AppBarTheme(
        centerTitle: false,
        backgroundColor: colorScheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        titleTextStyle: TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.w700,
          color: colorScheme.onSurface,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 68,
        backgroundColor: colorScheme.surfaceContainerLow,
        indicatorColor: colorScheme.primaryContainer,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return TextStyle(
            fontSize: 11,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            color: selected ? colorScheme.primary : colorScheme.onSurfaceVariant,
          );
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(
            size: 24,
            color: selected ? colorScheme.primary : colorScheme.onSurfaceVariant,
          );
        }),
      ),
    );
  }
}
