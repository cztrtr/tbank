import 'package:flutter/material.dart';

import '../models/question_bank_file.dart';
import '../services/app_config.dart';
import '../services/bank_io.dart';
import '../services/bank_repository.dart';
import '../services/study_history.dart';
import '../widgets/math_text.dart';

/// 学习统计页。
///
/// 扫描所有已添加的题库目录和 App 内置的 AI 题库，汇总：
/// - 总题数、总作答次数、总答错次数与整体正确率；
/// - 按题库文件夹分组的作答情况；
/// - 答错次数最多的前几道题；
/// - 连续打卡天数（来自 [AppConfig.clockOnNotifier]）。
class StatsPage extends StatefulWidget {
  const StatsPage({super.key});

  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage> {
  bool _loading = true;
  String? _error;
  _StatsData? _data;
  StudyHistoryData? _history;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final _StatsData data = await _computeStats();
      final StudyHistoryData history = await StudyHistory.load();
      if (!mounted) return;
      setState(() {
        _data = data;
        _history = history;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '读取统计失败：$error';
        _loading = false;
      });
    }
  }

  /// 扫描所有题库并汇总统计。
  Future<_StatsData> _computeStats() async {
    // 目录扫描与 AI 题库合并统一走 BankRepository（结果已按 uri 去重）
    final BankScanResult scan = await BankRepository.instance.listAll(
      refresh: true,
    );
    final List<QuestionBankFile> files = scan.files;

    // 解析在 BankRepository 的 isolate 里完成，并与管理页共享缓存。
    final Map<String, BankStat> stats = await BankRepository.instance.loadStats(
      files,
    );

    final Map<String, _GroupStat> groups = <String, _GroupStat>{};
    final List<({String question, int wrong})> wrongItems =
        <({String question, int wrong})>[];

    int totalQuestions = 0;
    int totalAttempt = 0;
    int totalWrong = 0;

    for (final QuestionBankFile file in files) {
      final BankStat? stat = stats[file.uri];
      if (stat == null) continue;

      final String groupName =
          file.directoryName ?? BankIo.displayNameOf(file.directoryRef);
      final _GroupStat group = groups.putIfAbsent(
        groupName,
        () => _GroupStat(name: groupName),
      );

      totalQuestions += stat.questionCount;
      totalAttempt += stat.attemptCount;
      totalWrong += stat.wrongCount;
      group.questionCount += stat.questionCount;
      group.attemptCount += stat.attemptCount;
      group.wrongCount += stat.wrongCount;
      wrongItems.addAll(stat.wrongItems);
    }

    wrongItems.sort(
      (({String question, int wrong}) a, ({String question, int wrong}) b) =>
          b.wrong.compareTo(a.wrong),
    );

    final List<_GroupStat> sortedGroups = groups.values.toList()
      ..sort((_GroupStat a, _GroupStat b) {
        return b.attemptCount.compareTo(a.attemptCount);
      });

    return _StatsData(
      groups: sortedGroups,
      topWrong: wrongItems.take(5).toList(),
      totalQuestions: totalQuestions,
      totalAttempt: totalAttempt,
      totalWrong: totalWrong,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('学习统计')),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

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

    final _StatsData data = _data!;
    final TextTheme textTheme = Theme.of(context).textTheme;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        // ---- 打卡 ----
        ValueListenableBuilder<int>(
          valueListenable: AppConfig.clockOnNotifier,
          builder: (BuildContext context, int days, _) {
            return Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                children: <Widget>[
                  Icon(
                    Icons.local_fire_department_outlined,
                    color: colorScheme.onPrimaryContainer,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    '连续打卡 $days 天',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: colorScheme.onPrimaryContainer,
                    ),
                  ),
                ],
              ),
            );
          },
        ),
        const SizedBox(height: 16),

        // ---- 总览 ----
        Row(
          children: <Widget>[
            Expanded(
              child: _StatCard(
                label: '总题数',
                value: '${data.totalQuestions}',
                colorScheme: colorScheme,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _StatCard(
                label: '总作答',
                value: '${data.totalAttempt}',
                colorScheme: colorScheme,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _StatCard(
                label: '正确率',
                value: data.accuracy == null
                    ? '—'
                    : '${(data.accuracy! * 100).toStringAsFixed(1)}%',
                colorScheme: colorScheme,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.only(left: 4),
          child: Text(
            '总答错 ${data.totalWrong} 次',
            style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
          ),
        ),
        const SizedBox(height: 20),

        // ---- 按天学习历史 ----
        _HistorySection(
          history: _history ?? StudyHistoryData(const <StudyDay>[]),
          colorScheme: colorScheme,
          textTheme: textTheme,
        ),
        const SizedBox(height: 20),

        // ---- 错得最多的题 ----
        if (data.topWrong.isNotEmpty) ...<Widget>[
          Text(
            '错得最多的题',
            style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          for (final ({String question, int wrong}) item in data.topWrong)
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: <Widget>[
                  Expanded(
                    // 题干可能内嵌 LaTeX，走 MathText 渲染公式，
                    // 仍然只显示两行，超出部分用省略号。
                    child: MathText(
                      item.question,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        color: colorScheme.onSurface,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    '错 ${item.wrong} 次',
                    style: TextStyle(fontSize: 12, color: colorScheme.error),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 12),
        ],

        // ---- 按题库分组 ----
        Text(
          '按题库统计',
          style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        if (data.groups.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 20),
            child: Center(
              child: Text(
                '还没有题库，先去「管理」页添加喵',
                style: TextStyle(color: colorScheme.onSurfaceVariant),
              ),
            ),
          )
        else
          for (final _GroupStat group in data.groups)
            Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                border: Border.all(color: colorScheme.outlineVariant),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Icon(
                        Icons.folder_outlined,
                        size: 16,
                        color: colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          group.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: colorScheme.onSurface,
                          ),
                        ),
                      ),
                      Text(
                        '${group.questionCount} 题',
                        style: TextStyle(
                          fontSize: 12,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '作答 ${group.attemptCount} 次 · 答错 '
                    '${group.wrongCount} 次 · 正确率 '
                    '${group.accuracy == null ? '—' : '${(group.accuracy! * 100).toStringAsFixed(1)}%'}',
                    style: TextStyle(
                      fontSize: 12,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 6),
                  LinearProgressIndicator(
                    value: group.accuracy ?? 0,
                    minHeight: 6,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ],
              ),
            ),
      ],
    );
  }
}

/// 总览里的一个小卡片。
class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.label,
    required this.value,
    required this.colorScheme,
  });

  final String label;
  final String value;
  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: <Widget>[
          Text(
            value,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: colorScheme.primary,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(fontSize: 11, color: colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// 按天学习历史：今日概览、最近 7 天柱状图、最近 30 天热力图。
class _HistorySection extends StatelessWidget {
  const _HistorySection({
    required this.history,
    required this.colorScheme,
    required this.textTheme,
  });

  final StudyHistoryData history;
  final ColorScheme colorScheme;
  final TextTheme textTheme;

  @override
  Widget build(BuildContext context) {
    final StudyDay today = history.today;
    final List<StudyDay> week = history.recentDays(7);
    final List<StudyDay> month = history.recentDays(30);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Text(
              '学习历史',
              style: textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            Text(
              history.isEmpty
                  ? '从本版开始记录'
                  : '累计 ${history.totalAttempts} 次 · 答错 ${history.totalWrong} 次',
              style: TextStyle(
                fontSize: 11,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: <Widget>[
            Expanded(
              child: _StatCard(
                label: '今日作答',
                value: '${today.attempts}',
                colorScheme: colorScheme,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _StatCard(
                label: '今日正确率',
                value: today.accuracy == null
                    ? '—'
                    : '${(today.accuracy! * 100).toStringAsFixed(0)}%',
                colorScheme: colorScheme,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _StatCard(
                label: '连续学习',
                value: '${history.currentStreak} 天',
                colorScheme: colorScheme,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Text(
          '最近 7 天',
          style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        _HistoryBarChart(days: week, colorScheme: colorScheme),
        const SizedBox(height: 16),
        Row(
          children: <Widget>[
            Text(
              '最近 30 天',
              style: textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            Text(
              ' ',
              style: TextStyle(
                fontSize: 11,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _HistoryHeatmap(days: month, colorScheme: colorScheme),
      ],
    );
  }
}

/// 7 天柱状图。
class _HistoryBarChart extends StatelessWidget {
  const _HistoryBarChart({required this.days, required this.colorScheme});

  final List<StudyDay> days;
  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    int maxAttempts = 0;
    for (final StudyDay day in days) {
      if (day.attempts > maxAttempts) maxAttempts = day.attempts;
    }

    return SizedBox(
      height: 112,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (final StudyDay day in days)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: Column(
                  children: <Widget>[
                    Text(
                      day.attempts == 0 ? '' : '${day.attempts}',
                      style: TextStyle(
                        fontSize: 10,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Expanded(
                      child: Align(
                        alignment: Alignment.bottomCenter,
                        child: FractionallySizedBox(
                          widthFactor: 0.55,
                          heightFactor: maxAttempts == 0
                              ? 0.04
                              : 0.08 + 0.92 * (day.attempts / maxAttempts),
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: day.attempts == 0
                                  ? colorScheme.surfaceContainerHighest
                                  : colorScheme.primary,
                              borderRadius: const BorderRadius.vertical(
                                top: Radius.circular(4),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _weekdayLabel(day.date),
                      style: TextStyle(
                        fontSize: 10,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 30 天热力图；每格一天，灰色表示没有作答。
class _HistoryHeatmap extends StatelessWidget {
  const _HistoryHeatmap({required this.days, required this.colorScheme});

  final List<StudyDay> days;
  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    int maxAttempts = 0;
    for (final StudyDay day in days) {
      if (day.attempts > maxAttempts) maxAttempts = day.attempts;
    }

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 10,
        mainAxisSpacing: 4,
        crossAxisSpacing: 4,
        childAspectRatio: 1.2,
      ),
      itemCount: days.length,
      itemBuilder: (BuildContext context, int index) {
        final StudyDay day = days[index];
        final double ratio = maxAttempts == 0
            ? 0
            : (day.attempts / maxAttempts).clamp(0.0, 1.0);
        final Color color = day.attempts == 0
            ? colorScheme.surfaceContainerHighest
            : (Color.lerp(
                    colorScheme.primaryContainer,
                    colorScheme.primary,
                    0.15 + ratio * 0.85,
                  ) ??
                  colorScheme.primary);
        final String rate = day.accuracy == null
            ? '无作答'
            : '正确率 ${(day.accuracy! * 100).toStringAsFixed(0)}%';
        final String message = '${_monthDay(day.date)}：${day.attempts} 题，$rate';

        return Tooltip(
          message: message,
          child: Semantics(
            label: message,
            child: Container(
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
        );
      },
    );
  }
}

String _weekdayLabel(DateTime date) {
  const List<String> labels = <String>['一', '二', '三', '四', '五', '六', '日'];
  return labels[(date.weekday - 1).clamp(0, 6)];
}

String _monthDay(DateTime date) => '${date.month}/${date.day}';

/// 一个题库文件夹的统计。
class _GroupStat {
  _GroupStat({required this.name});

  final String name;
  int questionCount = 0;
  int attemptCount = 0;
  int wrongCount = 0;

  /// 正确率；一次都没作答时为 null。
  double? get accuracy =>
      attemptCount == 0 ? null : 1 - wrongCount / attemptCount;
}

/// 全量统计数据。
class _StatsData {
  _StatsData({
    required this.groups,
    required this.topWrong,
    required this.totalQuestions,
    required this.totalAttempt,
    required this.totalWrong,
  });

  final List<_GroupStat> groups;
  final List<({String question, int wrong})> topWrong;
  final int totalQuestions;
  final int totalAttempt;
  final int totalWrong;

  double? get accuracy =>
      totalAttempt == 0 ? null : 1 - totalWrong / totalAttempt;
}
