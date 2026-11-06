import 'dart:io';

import 'package:flutter/material.dart';

import '../models/question_bank_file.dart';
import '../services/ai_question_generator.dart';
import '../services/ds_api_service.dart';
import 'practice_page.dart';

/// AI 出题页。
///
/// 用户输入主题与出题要求，勾选题型和数量（5~100，每本最多 25 道），
/// AI 生成练习题并按「每本最多 25 道」保存到 App 私有目录的
/// `Question/<主题>/<主题>-时间戳-<批次>.json`（标准题库 JSON 格式）。
/// 页面下方列出已生成的题库，点开即可练习。
class AiGeneratePage extends StatefulWidget {
  const AiGeneratePage({super.key});

  @override
  State<AiGeneratePage> createState() => _AiGeneratePageState();
}

class _AiGeneratePageState extends State<AiGeneratePage> {
  final TextEditingController _topicController = TextEditingController();
  final TextEditingController _requirementsController = TextEditingController();

  /// 已选题型（中文标签），默认全选。
  ///
  /// 填空、名词解释、解答、证明在数据层统一存为 `fill_blank`，由 AI 判分；
  /// 完整标签列表见 [AiQuestionGenerator.allTypeLabels]。
  final Set<String> _selectedTypes = <String>{
    ...AiQuestionGenerator.allTypeLabels,
  };

  bool _generating = false;
  String? _error;

  /// 一次生成的目标题目数量（每本上限 25 道，超出会分成多本）。
  int _count = 25;

  /// 分批生成进度：(已完成, 目标)。
  ({int finished, int total})? _progress;

  bool _loadingBanks = true;
  List<AiBankInfo> _banks = const <AiBankInfo>[];

  @override
  void initState() {
    super.initState();
    _loadBanks();
  }

  @override
  void dispose() {
    _topicController.dispose();
    _requirementsController.dispose();
    super.dispose();
  }

  Future<void> _loadBanks() async {
    final List<AiBankInfo> banks = await AiQuestionGenerator.listBanks();
    if (!mounted) return;
    setState(() {
      _banks = banks;
      _loadingBanks = false;
    });
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _generate() async {
    final String topic = _topicController.text.trim();
    final String requirements = _requirementsController.text.trim();

    if (topic.isEmpty) {
      _toast('请先输入主题（会作为题库文件夹名）');
      return;
    }
    if (requirements.isEmpty) {
      _toast('请先输入出题要求 / 知识点');
      return;
    }
    if (_selectedTypes.isEmpty) {
      _toast('至少选择一种题型');
      return;
    }

    setState(() {
      _generating = true;
      _error = null;
      _progress = null;
    });

    try {
      final List<AiBankInfo> banks = await AiQuestionGenerator.generateAndSave(
        topic: topic,
        requirements: requirements,
        types: _selectedTypes.toList(),
        count: _count,
        onProgress: (int finished, int total) {
          if (!mounted) return;
          setState(() => _progress = (finished: finished, total: total));
        },
      );
      if (!mounted) return;

      final int totalQuestions = banks.fold<int>(
        0,
        (int sum, AiBankInfo bank) => sum + bank.questionCount,
      );
      _toast('已生成 $totalQuestions 道题，保存为 ${banks.length} 本');
      await _loadBanks();
    } on DsApiException catch (error) {
      if (!mounted) return;
      setState(() => _error = error.message);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = '出题失败：$error');
    } finally {
      if (mounted) {
        setState(() {
          _generating = false;
          _progress = null;
        });
      }
    }
  }

  void _openBank(AiBankInfo bank) {
    Navigator.of(context)
        .push(
          MaterialPageRoute<void>(
            builder: (_) => PracticePage(
              bank: QuestionBankFile(
                name: bank.fileName,
                uri: bank.path,
                directoryRef: File(bank.path).parent.path,
                directoryName: bank.topic,
              ),
            ),
          ),
        )
        .then((_) => _loadBanks());
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    final TextTheme textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('AI 出题')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          // ---- 主题 ----
          Text(
            '主题',
            style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _topicController,
            enabled: !_generating,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
              hintText: '如：大学物理学',
              isDense: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
          const SizedBox(height: 14),

          // ---- 出题要求 ----
          Text(
            '出题要求 / 知识点',
            style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _requirementsController,
            enabled: !_generating,
            minLines: 3,
            maxLines: 6,
            decoration: InputDecoration(
              hintText: '如：力学、热学、电磁学基础概念，选择题为主，难度适中',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
          const SizedBox(height: 14),

          // ---- 题型 ----
          Text(
            '题型',
            style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            children: <Widget>[
              for (final String label in AiQuestionGenerator.allTypeLabels)
                FilterChip(
                  label: Text(label),
                  selected: _selectedTypes.contains(label),
                  onSelected: _generating
                      ? null
                      : (bool selected) => setState(() {
                          if (selected) {
                            _selectedTypes.add(label);
                          } else {
                            _selectedTypes.remove(label);
                          }
                        }),
                ),
            ],
          ),
          const SizedBox(height: 14),

          // ---- 题目数量 ----
          Text(
            '题目数量',
            style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          DropdownButtonFormField<int>(
            initialValue: _count,
            decoration: InputDecoration(
              isDense: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            items: <DropdownMenuItem<int>>[
              for (final int value in const <int>[
                5,
                10,
                15,
                20,
                25,
                30,
                40,
                50,
                75,
                100,
              ])
                DropdownMenuItem<int>(value: value, child: Text('$value 道')),
            ],
            onChanged: _generating
                ? null
                : (int? value) {
                    if (value != null) {
                      setState(() => _count = value);
                    }
                  },
          ),
          const SizedBox(height: 4),
          Text(
            '每本（一个 JSON 文件）最多 25 道，超过会自动分成多本',
            style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),

          // ---- 生成按钮 ----
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _generating ? null : _generate,
              icon: _generating
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.auto_awesome, size: 20),
              label: Text(_generating ? 'AI 正在出题…' : '生成 $_count 道题'),
            ),
          ),
          if (_generating)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                _progress == null
                    ? '正在生成，每本最多 25 道，首批通常需要 30~90 秒'
                    : '正在生成：已完成 ${_progress!.finished} / ${_progress!.total} 道',
                style: TextStyle(
                  fontSize: 12,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),

          // ---- 错误提示 ----
          if (_error != null) ...<Widget>[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                _error!,
                style: TextStyle(
                  fontSize: 13,
                  color: colorScheme.onErrorContainer,
                ),
              ),
            ),
          ],

          const SizedBox(height: 24),
          const Divider(),
          const SizedBox(height: 12),

          // ---- 已生成的题库 ----
          Text(
            '已生成的题库',
            style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          ..._buildBankList(colorScheme),
        ],
      ),
    );
  }

  /// 已生成的题库列表：按主题分组，点击进入练习。
  List<Widget> _buildBankList(ColorScheme colorScheme) {
    if (_loadingBanks) {
      return <Widget>[
        const Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    }

    if (_banks.isEmpty) {
      return <Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 20),
          child: Center(
            child: Text(
              '还没有生成过题目',
              style: TextStyle(color: colorScheme.onSurfaceVariant),
            ),
          ),
        ),
      ];
    }

    final Map<String, List<AiBankInfo>> groups = <String, List<AiBankInfo>>{};
    for (final AiBankInfo bank in _banks) {
      groups.putIfAbsent(bank.topic, () => <AiBankInfo>[]).add(bank);
    }

    return <Widget>[
      for (final MapEntry<String, List<AiBankInfo>> group
          in groups.entries) ...<Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(0, 12, 0, 4),
          child: Row(
            children: <Widget>[
              Icon(
                Icons.folder_outlined,
                size: 18,
                color: colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  group.key,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
        for (final AiBankInfo bank in group.value)
          Padding(
            padding: const EdgeInsets.only(left: 6),
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
              leading: Icon(Icons.quiz_outlined, color: colorScheme.primary),
              title: Text(
                bank.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text('${bank.questionCount} 题'),
              onTap: () => _openBank(bank),
            ),
          ),
      ],
    ];
  }
}
