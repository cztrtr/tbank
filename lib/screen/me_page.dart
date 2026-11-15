import 'dart:async';

import 'package:flutter/material.dart';

import '../services/study_history.dart';
import 'ai_generate_page.dart';
import 'book_ai_generate_page.dart';
import 'mistake_books_page.dart';
import 'quick_start_page.dart';
import 'settings_page.dart';
import 'stats_page.dart';

/// 个人中心。
///
/// 提供「快速开始」「学习统计」「错题本」「AI 出题」「拍书出题」「设置」
/// 六个入口；学习统计入口直接展示今日与近 7 天摘要。
class MePage extends StatefulWidget {
  const MePage({super.key});

  @override
  State<MePage> createState() => _MePageState();
}

class _MePageState extends State<MePage> {
  @override
  void initState() {
    super.initState();
    unawaited(StudyHistory.load());
  }

  Future<void> _openStats() async {
    await Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const StatsPage()));
    if (mounted) unawaited(StudyHistory.load());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('我的')),
      body: ListView(
        // 四周留出边距，按钮不贴边
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
        children: <Widget>[
          // 快速开始：六步上手说明，内容来自 assets/texts/quick_start.md
          SizedBox(
            width: double.infinity,
            child: FilledButton.tonalIcon(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const QuickStartPage(),
                  ),
                );
              },
              icon: const Icon(Icons.rocket_launch_outlined, size: 20),
              label: const Text('快速开始'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),

          // 学习统计：入口直接展示今日和近 7 天，点进去看完整统计。
          ValueListenableBuilder<StudyHistoryData>(
            valueListenable: StudyHistory.notifier,
            builder:
                (BuildContext context, StudyHistoryData history, Widget? _) {
                  return _StudySummaryCard(history: history, onTap: _openStats);
                },
          ),
          const SizedBox(height: 12),

          // 错题本：收集所有题库里答错过的题，按本练习
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const MistakeBooksPage(),
                  ),
                );
              },
              icon: const Icon(Icons.menu_book_outlined, size: 20),
              label: const Text('错题本'),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),

          // AI 出题：按主题和要求生成练习题，保存到 App 私有目录的 Question/
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const AiGeneratePage(),
                  ),
                );
              },
              icon: const Icon(Icons.auto_awesome_outlined, size: 20),
              label: const Text('AI 出题'),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),

          // 拍书出题：拍教材题目 / 知识点，AI 识别后出题，可自定义保存位置
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const BookAiGeneratePage(),
                  ),
                );
              },
              icon: const Icon(Icons.photo_camera_outlined, size: 20),
              label: const Text('拍书出题'),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),

          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const SettingsPage()),
                );
              },
              icon: const Icon(Icons.settings_outlined, size: 20),
              label: const Text('设置'),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 「我的」页的学习统计摘要卡片：今日、连续学习和近 7 天迷你柱状图。
class _StudySummaryCard extends StatelessWidget {
  const _StudySummaryCard({required this.history, required this.onTap});

  final StudyHistoryData history;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    final StudyDay today = history.today;
    final List<StudyDay> week = history.recentDays(7);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: colorScheme.outlineVariant),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(
                    Icons.bar_chart_outlined,
                    size: 20,
                    color: colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '学习统计',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: colorScheme.onSurface,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '查看详情',
                    style: TextStyle(fontSize: 12, color: colorScheme.primary),
                  ),
                  Icon(
                    Icons.chevron_right,
                    size: 18,
                    color: colorScheme.primary,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: <Widget>[
                  _SummaryMetric(
                    label: '今日',
                    value: '${today.attempts} 题',
                    colorScheme: colorScheme,
                  ),
                  const SizedBox(width: 18),
                  _SummaryMetric(
                    label: '正确率',
                    value: today.accuracy == null
                        ? '—'
                        : '${(today.accuracy! * 100).toStringAsFixed(0)}%',
                    colorScheme: colorScheme,
                  ),
                  const SizedBox(width: 18),
                  _SummaryMetric(
                    label: '连续',
                    value: '${history.currentStreak} 天',
                    colorScheme: colorScheme,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                history.isEmpty ? '答题后这里会出现最近 7 天记录' : '最近 7 天',
                style: TextStyle(
                  fontSize: 11,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 4),
              _MiniWeekBars(days: week, colorScheme: colorScheme),
            ],
          ),
        ),
      ),
    );
  }
}

class _SummaryMetric extends StatelessWidget {
  const _SummaryMetric({
    required this.label,
    required this.value,
    required this.colorScheme,
  });

  final String label;
  final String value;
  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: colorScheme.primary,
            ),
          ),
          const SizedBox(height: 1),
          Text(
            label,
            style: TextStyle(fontSize: 10, color: colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _MiniWeekBars extends StatelessWidget {
  const _MiniWeekBars({required this.days, required this.colorScheme});

  final List<StudyDay> days;
  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    int maxAttempts = 0;
    for (final StudyDay day in days) {
      if (day.attempts > maxAttempts) maxAttempts = day.attempts;
    }

    return SizedBox(
      height: 34,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          for (final StudyDay day in days)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: FractionallySizedBox(
                  heightFactor: maxAttempts == 0
                      ? 0.12
                      : 0.15 + 0.85 * (day.attempts / maxAttempts),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: day.attempts == 0
                          ? colorScheme.surfaceContainerHighest
                          : colorScheme.primary,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
