import 'package:flutter/material.dart';

/// 页面占位：只保留标题和占位图形，具体内容后续再填充。
///
/// 目前只有 MePage 用它。Home 已经有真实内容（随机背景 + 打卡卡片 +
/// 语录卡），不再走这个占位；做 ME 页面时把它的 build 换成自己的
/// Scaffold body 即可，届时这个组件就可以删掉。
class PagePlaceholder extends StatelessWidget {
  const PagePlaceholder({
    super.key,
    required this.title,
    required this.icon,
  });

  /// AppBar 标题，同时作为占位文案。
  final String title;

  /// 中间显示的图标。
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 56, color: colorScheme.outline),
            const SizedBox(height: 14),
            Text(
              title,
              style: theme.textTheme.titleMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
