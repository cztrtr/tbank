import 'package:flutter/material.dart';

/// 练习完成页：本次成绩 + 回拷状态 + 再练一遍。
class PracticeFinishedView extends StatelessWidget {
  const PracticeFinishedView({
    super.key,
    required this.total,
    required this.answeredCount,
    required this.correctCount,
    required this.syncMessage,
    required this.onRestart,
  });

  final int total;
  final int answeredCount;
  final int correctCount;
  final String? syncMessage;
  final VoidCallback onRestart;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.check_circle_outline,
              size: 72,
              color: colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text(
              '练习完成',
              style: Theme.of(context).textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            Text(
              '共 $total 题，本次作答 $answeredCount 题，答对 $correctCount 题',
              textAlign: TextAlign.center,
            ),
            if (syncMessage != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                syncMessage!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: onRestart,
                child: const Text('再练一遍'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
