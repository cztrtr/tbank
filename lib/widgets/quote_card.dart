import 'dart:math';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 半透明圆角矩形卡片，展示一句从 assets 文本里随机取出的文字。
///
/// 文本文件约定（UTF-8）：
/// - 一行一句；
/// - 空行自动忽略；
/// - 以 `#` 开头的行当作注释，不会显示。
///
/// 行为：
/// - 启动时随机取一句；
/// - 点击卡片换下一句，且不会连续两次显示同一句；
/// - 只有一句、或文件加载失败时点击无效果，卡片会隐藏。
class QuoteCard extends StatefulWidget {
  const QuoteCard({
    super.key,
    this.assetPath = 'assets/texts/quotes.txt',
  });

  /// 文字资源路径，必须已在 pubspec.yaml 的 assets 里声明。
  final String assetPath;

  @override
  State<QuoteCard> createState() => _QuoteCardState();
}

class _QuoteCardState extends State<QuoteCard> {
  final Random _random = Random();

  List<String> _lines = const <String>[];
  int _index = 0;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _loadLines();
  }

  Future<void> _loadLines() async {
    try {
      final raw = await rootBundle.loadString(widget.assetPath);
      final lines = raw
          .split(RegExp(r'\r?\n'))
          .map((String line) => line.trim())
          .where((String line) => line.isNotEmpty && !line.startsWith('#'))
          .toList(growable: false);

      if (!mounted) return;
      setState(() {
        _lines = lines;
        _loaded = true;
        if (lines.isNotEmpty) {
          _index = _random.nextInt(lines.length);
        }
      });
    } catch (error) {
      debugPrint('加载语录失败（${widget.assetPath}）：$error');
      if (!mounted) return;
      setState(() => _loaded = true);
    }
  }

  /// 换一句：随机，但不与当前这句重复。
  void _showNext() {
    if (_lines.length < 2) return;

    int next = _index;
    while (next == _index) {
      next = _random.nextInt(_lines.length);
    }
    setState(() => _index = next);
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded || _lines.isEmpty) {
      return const SizedBox.shrink();
    }

    final String text = _lines[_index];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(22),
        child: BackdropFilter(
          // 和打卡卡片一致的毛玻璃质感
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Material(
            color: Colors.white.withValues(alpha: 0.16),
            child: InkWell(
              onTap: _showNext,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 16,
                ),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.28),
                  ),
                ),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 260),
                  switchInCurve: Curves.easeOut,
                  switchOutCurve: Curves.easeIn,
                  transitionBuilder: (Widget child, Animation<double> animation) {
                    return FadeTransition(
                      opacity: animation,
                      child: SlideTransition(
                        position: Tween<Offset>(
                          begin: const Offset(0, 0.15),
                          end: Offset.zero,
                        ).animate(animation),
                        child: child,
                      ),
                    );
                  },
                  child: Text(
                    text,
                    key: ValueKey<String>(text),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 15,
                      height: 1.5,
                      fontWeight: FontWeight.w500,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
