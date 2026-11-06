import 'dart:convert';

import 'package:flutter/material.dart';

import '../models/question_bank_file.dart';
import '../services/app_config.dart';
import '../services/bank_io.dart';
import '../services/bank_repository.dart';
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
      if (!mounted) return;
      setState(() {
        _data = data;
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
    final BankScanResult scan =
        await BankRepository.instance.listAll(refresh: true);
    final List<QuestionBankFile> files = scan.files;

    final Map<String, _GroupStat> groups = <String, _GroupStat>{};
    final List<({String question, int wrong})> wrongItems =
        <({String question, int wrong})>[];

    int totalQuestions = 0;
    int totalAttempt = 0;
    int totalWrong = 0;

    for (final QuestionBankFile file in files) {
      try {
        final dynamic decoded = jsonDecode(await BankIo.readText(file.uri));
        if (decoded is! Map || decoded['questions'] is! List) continue;

        final String groupName =
            file.directoryName ?? BankIo.displayNameOf(file.directoryRef);
        final _GroupStat group = groups.putIfAbsent(
          groupName,
          () => _GroupStat(name: groupName),
        );

        for (final dynamic item in decoded['questions'] as List) {
          if (item is! Map) continue;

          final dynamic stats = item['stats'];
          final int attempt = stats is Map && stats['attemptCount'] is num
              ? (stats['attemptCount'] as num).toInt()
              : 0;
          final int wrong = stats is Map && stats['wrongCount'] is num
              ? (stats['wrongCount'] as num).toInt()
              : 0;

          totalQuestions += 1;
          totalAttempt += attempt;
          totalWrong += wrong;
          group.questionCount += 1;
          group.attemptCount += attempt;
          group.wrongCount += wrong;

          if (wrong > 0) {
            final String text = item['question']?.toString().trim() ?? '';
            if (text.isNotEmpty) {
              wrongItems.add((question: text, wrong: wrong));
            }
          }
        }
      } catch (error) {
        // 单个文件损坏：跳过，不影响整体统计
        debugPrint('统计题库失败：${file.uri} $error');
      }
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
