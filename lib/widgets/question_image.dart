import 'dart:io';

import 'package:flutter/material.dart';

/// 题目配图：从题库 JSON 所在目录加载一张图片。
///
/// 约定：
/// - `fileName` 只是文件名，例如 `q001.png`，不带路径；
/// - 图片必须和题库 JSON 放在同一个目录，`directory` 由
///   `QuestionBankStorage.sourceDir` 提供；
/// - 一道题最多一张图。
///
/// 三种异常都会退化成占位框并把文件名显示出来，方便定位配置错误：
/// 目录未知、文件不存在、文件无法解码。
class QuestionImage extends StatelessWidget {
  const QuestionImage({
    super.key,
    required this.fileName,
    required this.directory,
    this.maxHeight = 320,
  });

  /// 图片文件名；为空表示这道题没有配图，直接不占位置。
  final String fileName;

  /// 图片所在目录的绝对路径；为 null 表示题库目录还没解析出来。
  final String? directory;

  /// 图片显示的最大高度，避免长图把整页撑得很长。
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    final String name = fileName.trim();
    if (name.isEmpty) {
      return const SizedBox.shrink();
    }

    final String? baseDir = directory;
    if (baseDir == null || baseDir.isEmpty) {
      return _buildPlaceholder(context, name, '题库目录未就绪');
    }

    final File file = File('$baseDir${Platform.pathSeparator}$name');
    if (!file.existsSync()) {
      return _buildPlaceholder(context, name, '图片不存在');
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: Image.file(
            file,
            width: double.infinity,
            fit: BoxFit.contain,
            // 文件损坏、格式不支持等解码失败时也走占位框
            errorBuilder: (BuildContext context, Object error, StackTrace? _) {
              return _buildPlaceholder(context, name, '图片无法解码');
            },
          ),
        ),
      ),
    );
  }

  /// 图片不可用时的占位块：图标 + 原因 + 文件名。
  Widget _buildPlaceholder(
    BuildContext context,
    String name,
    String reason,
  ) {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Column(
        children: <Widget>[
          Icon(
            Icons.broken_image_outlined,
            size: 32,
            color: colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 8),
          Text(
            '$reason：$name',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
