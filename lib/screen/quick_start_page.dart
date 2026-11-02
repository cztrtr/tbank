import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

/// 「快速开始」页。
///
/// 内容来自随包发布的 `assets/texts/quick_start.md`，方便以后直接改文档、
/// 不用动代码。这里只实现文档里用到的少量 Markdown 语法：
/// 一级/二级/三级标题、无序列表、`**粗体**` 和空行分段。
class QuickStartPage extends StatefulWidget {
  const QuickStartPage({super.key});

  @override
  State<QuickStartPage> createState() => _QuickStartPageState();
}

class _QuickStartPageState extends State<QuickStartPage> {
  static const String _assetPath = 'assets/texts/quick_start.md';

  bool _loading = true;
  String? _error;
  String _text = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final String text = await rootBundle.loadString(_assetPath);
      if (!mounted) return;
      setState(() {
        _text = text;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '读取快速开始文档失败：$error';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('快速开始')),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final ColorScheme colorScheme = Theme.of(context).colorScheme;

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.error_outline, size: 48, color: colorScheme.error),
              const SizedBox(height: 12),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(color: colorScheme.error),
              ),
              const SizedBox(height: 16),
              FilledButton(onPressed: _load, child: const Text('重试')),
            ],
          ),
        ),
      );
    }

    final TextTheme textTheme = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
      children: _buildMarkdown(textTheme),
    );
  }

  /// 把 Markdown 文本拆成一组简单排版的 Widget。
  List<Widget> _buildMarkdown(TextTheme textTheme) {
    final List<Widget> widgets = <Widget>[];
    bool firstHeadingSkipped = false; // 页面标题由 AppBar 承担，跳过文档首个 # 标题

    for (final String rawLine in _text.split('\n')) {
      final String line = rawLine.trimRight();
      if (line.trim().isEmpty) {
        widgets.add(const SizedBox(height: 8));
        continue;
      }

      if (line.startsWith('### ')) {
        widgets.add(
          _heading(line.substring(4), textTheme.titleMedium, top: 12),
        );
      } else if (line.startsWith('## ')) {
        widgets.add(_heading(line.substring(3), textTheme.titleLarge, top: 16));
      } else if (line.startsWith('# ')) {
        if (!firstHeadingSkipped) {
          firstHeadingSkipped = true;
          continue;
        }
        widgets.add(
          _heading(line.substring(2), textTheme.headlineSmall, top: 16),
        );
      } else if (line.startsWith('- ')) {
        widgets.add(_bullet(line.substring(2), textTheme));
      } else {
        widgets.add(_paragraph(line, textTheme));
      }
    }
    return widgets;
  }

  Widget _heading(String text, TextStyle? base, {double top = 12}) {
    final TextStyle style = (base ?? const TextStyle(fontSize: 18)).copyWith(
      fontWeight: FontWeight.w700,
    );
    return Padding(
      padding: EdgeInsets.only(top: top, bottom: 6),
      child: _richText(text, style),
    );
  }

  Widget _bullet(String text, TextTheme textTheme) {
    final TextStyle style =
        textTheme.bodyMedium ?? const TextStyle(fontSize: 14);
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 1, right: 8),
            child: Text(
              '•',
              style: style.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          Expanded(child: _richText(text, style)),
        ],
      ),
    );
  }

  Widget _paragraph(String text, TextTheme textTheme) {
    final TextStyle style =
        textTheme.bodyMedium ?? const TextStyle(fontSize: 14);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: _richText(text, style),
    );
  }

  /// 渲染一行文字，支持 `**粗体**` 与 `` `行内代码` ``。
  Widget _richText(String text, TextStyle style) {
    final RegExp pattern = RegExp(r'\*\*(.+?)\*\*|`([^`]+)`');
    final List<InlineSpan> spans = <InlineSpan>[];
    int start = 0;

    for (final Match match in pattern.allMatches(text)) {
      if (match.start > start) {
        spans.add(TextSpan(text: text.substring(start, match.start)));
      }

      final String? code = match.group(2);
      if (code != null) {
        // 行内代码：去掉反引号，用等宽字体显示
        spans.add(
          TextSpan(
            text: code,
            style: const TextStyle(fontFamily: 'monospace'),
          ),
        );
      } else {
        spans.add(
          TextSpan(
            text: match.group(1),
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        );
      }
      start = match.end;
    }
    if (start < text.length) {
      spans.add(TextSpan(text: text.substring(start)));
    }

    return RichText(
      text: TextSpan(style: style, children: spans),
    );
  }
}
