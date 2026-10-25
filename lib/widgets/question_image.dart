import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../services/bank_io.dart';

/// 题目配图：从题库 JSON 所在目录加载一张图片。
///
/// 约定：
/// - `fileName` 只是文件名，例如 `q001.png`，不带路径；
/// - 图片必须和题库 JSON 放在同一个目录，`directoryRef` 由
///   `QuestionBankStorage.sourceDirectoryRef` 提供；
/// - 一道题最多一张图。
///
/// 图片通过 [BankIo] 读成字节后用 `Image.memory` 渲染，因此 Android 上
/// 的 `content://` 目录和桌面的文件路径都能用。
///
/// 三种异常都会退化成占位框并把文件名显示出来，方便定位配置错误：
/// 目录未知、文件不存在、文件无法解码。
class QuestionImage extends StatefulWidget {
  const QuestionImage({
    super.key,
    required this.fileName,
    required this.directoryRef,
    this.maxHeight = 320,
  });

  /// 图片文件名；为空表示这道题没有配图，直接不占位置。
  final String fileName;

  /// 图片所在目录的引用（SAF URI 或桌面路径）；为 null 表示题库目录还没解析出来。
  final String? directoryRef;

  /// 图片显示的最大高度，避免长图把整页撑得很长。
  final double maxHeight;

  @override
  State<QuestionImage> createState() => _QuestionImageState();
}

class _QuestionImageState extends State<QuestionImage> {
  Future<Uint8List?>? _future;

  @override
  void initState() {
    super.initState();
    _startLoad();
  }

  @override
  void didUpdateWidget(covariant QuestionImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 换题时目录和文件名都可能变，需要重新读
    if (oldWidget.fileName != widget.fileName ||
        oldWidget.directoryRef != widget.directoryRef) {
      _startLoad();
    }
  }

  void _startLoad() {
    final String directory = (widget.directoryRef ?? '').trim();
    final String name = widget.fileName.trim();
    if (directory.isEmpty || name.isEmpty) {
      _future = null;
      return;
    }
    _future = _loadBytes(directory, name);
  }

  Future<Uint8List?> _loadBytes(String directory, String name) async {
    try {
      return await BankIo.readSiblingBytes(directory, name);
    } catch (_) {
      // 授权失效、文件被删、读取异常都归为「取不到图」
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final String name = widget.fileName.trim();
    if (name.isEmpty) {
      return const SizedBox.shrink();
    }

    final String directory = (widget.directoryRef ?? '').trim();
    if (directory.isEmpty) {
      return _buildPlaceholder(context, name, '题库目录未就绪');
    }

    return FutureBuilder<Uint8List?>(
      future: _future,
      builder: (BuildContext context, AsyncSnapshot<Uint8List?> snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return _buildLoading(context);
        }

        final Uint8List? bytes = snapshot.data;
        if (bytes == null || bytes.isEmpty) {
          return _buildPlaceholder(context, name, '图片不存在');
        }

        return Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: widget.maxHeight),
              child: Image.memory(
                bytes,
                width: double.infinity,
                fit: BoxFit.contain,
                // 文件损坏、格式不支持等解码失败时也走占位框
                errorBuilder:
                    (BuildContext context, Object error, StackTrace? _) {
                  return _buildPlaceholder(context, name, '图片无法解码');
                },
              ),
            ),
          ),
        );
      },
    );
  }

  /// 读取中的占位，避免图片出现时页面高度突跳。
  Widget _buildLoading(BuildContext context) {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;

    return Container(
      width: double.infinity,
      height: 80,
      margin: const EdgeInsets.only(bottom: 16),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: const SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
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
