// AI 变式出题页：读一份已有题库 → 自动归纳知识点 → 重新出题。
//
// 生成结果保存到原题库所在目录，文件名按希腊字母递增：
// `xxx-alpha.json` → `xxx-beta.json` → `xxx-gamma.json` …
// 由题库管理页（QuestionBankPage）进入，返回后管理页会重新扫描。
import 'package:flutter/material.dart';

import '../models/question_bank.dart';
import '../models/question_bank_file.dart';
import '../services/ai_question_generator.dart';
import '../services/variant_question_generator.dart';
import '../services/ds_api_service.dart';

/// 可选题型：与 AI 出题页共用完整标签列表。
///
/// 单选 / 多选 / 判断有独立数据层类型；填空、名词解释、解答、证明
/// 在数据层统一存为 `fill_blank`。
const List<String> _typeOrder = AiQuestionGenerator.allTypeLabels;

/// 题量下拉的固定档位；原题库题数不在档位里时会额外补一项。
const List<int> _countPresets = <int>[5, 10, 15, 20, 25, 30, 40, 50, 75, 100];

class VariantGeneratePage extends StatefulWidget {
  const VariantGeneratePage({super.key, required this.source});

  /// 作为出题依据的原题库文件。
  final QuestionBankFile source;

  @override
  State<VariantGeneratePage> createState() => _VariantGeneratePageState();
}

class _VariantGeneratePageState extends State<VariantGeneratePage> {
  bool _loading = true;
  String? _loadError;

  /// 已解析的原题库；加载失败时为 null。
  QuestionBank? _bank;

  /// 本次将要写入的目标文件名（按希腊字母自动取下一个）。
  String? _targetFileName;

  bool _generating = false;
  String? _error;
  VariantProgress? _progress;
  VariantResult? _result;

  /// 目标题数，默认与原题库一致（上限 100）。
  int _count = 25;

  /// 已选题型（中文标签），默认沿用原题库出现过的题型。
  final Set<String> _selectedTypes = <String>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final QuestionBank bank = await VariantQuestionGenerator.loadBank(
        widget.source,
      );
      final String targetFileName = await VariantQuestionGenerator.nextFileName(
        widget.source,
      );
      if (!mounted) return;

      setState(() {
        _bank = bank;
        _targetFileName = targetFileName;
        _selectedTypes.addAll(VariantQuestionGenerator.typesOf(bank));
        _count = bank.questions.length
            .clamp(5, VariantQuestionGenerator.maxCount)
            .toInt();
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = '读取题库失败：$error';
        _loading = false;
      });
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  /// 下拉里展示的全部题量档位。
  List<int> get _countOptions {
    final Set<int> values = <int>{..._countPresets, _count};
    final List<int> list = values
        .where(
          (int value) =>
              value >= 1 && value <= VariantQuestionGenerator.maxCount,
        )
        .toList();
    list.sort();
    return list;
  }

  Future<void> _generate() async {
    final QuestionBank? bank = _bank;
    if (bank == null) return;

    if (_selectedTypes.isEmpty) {
      _toast('至少选择一种题型');
      return;
    }

    setState(() {
      _generating = true;
      _error = null;
      _progress = null;
      _result = null;
    });

    try {
      final VariantResult result = await VariantQuestionGenerator.generate(
        source: widget.source,
        sourceBank: bank,
        count: _count,
        types: _typeOrder.where(_selectedTypes.contains).toList(),
        onProgress: (VariantProgress progress) {
          if (!mounted) return;
          setState(() => _progress = progress);
        },
      );
      if (!mounted) return;

      // 生成成功后目录里多了一个文件，重新计算下一次的目标名
      final String nextName = await VariantQuestionGenerator.nextFileName(
        widget.source,
      );
      if (!mounted) return;

      setState(() {
        _result = result;
        _targetFileName = nextName;
      });
      _toast('已生成 ${result.count} 道变式题：${result.fileName}');
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

  /// 当前应该展示的知识点：优先展示最后一次进度里的，其次展示结果里的。
  List<String> get _knowledgePoints {
    final List<String> fromProgress =
        _progress?.knowledgePoints ?? const <String>[];
    if (fromProgress.isNotEmpty) return fromProgress;
    return _result?.knowledgePoints ?? const <String>[];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('AI 变式出题')),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_loadError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.error_outline, size: 48, color: colorScheme.error),
              const SizedBox(height: 12),
              Text(
                _loadError!,
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

    final QuestionBank bank = _bank!;
    final TextTheme textTheme = Theme.of(context).textTheme;
    final List<String> points = _knowledgePoints;
    final VariantProgress? progress = _progress;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        // ---- 源题库信息 ----
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(Icons.description_outlined, color: colorScheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.source.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '共 ${bank.questions.length} 题 · 题型：'
                '${VariantQuestionGenerator.typesOf(bank).join(' / ')}',
                style: TextStyle(
                  fontSize: 13,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '新题目会保存到同一个目录：${_targetFileName ?? ''}',
                style: TextStyle(
                  fontSize: 13,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '文件名按希腊字母递增（alpha → beta → gamma…），不会覆盖已有题库',
                  style: TextStyle(
                    fontSize: 12,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

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
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
          items: <DropdownMenuItem<int>>[
            for (final int value in _countOptions)
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
          '默认与原题库题数一致，超过 100 按 100 算',
          style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
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
            for (final String label in _typeOrder)
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
            label: Text(_generating ? 'AI 正在出题…' : '基于知识点重新出题'),
          ),
        ),

        // ---- 进度 ----
        if (_generating && progress != null) ...<Widget>[
          const SizedBox(height: 10),
          Text(
            _stageText(progress),
            style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
          ),
          if (progress.total > 0) ...<Widget>[
            const SizedBox(height: 6),
            LinearProgressIndicator(value: progress.finished / progress.total),
          ],
        ],

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

        // ---- 知识点 ----
        if (points.isNotEmpty) ...<Widget>[
          const SizedBox(height: 20),
          Text(
            '本题库涉及的知识点（${points.length} 个）',
            style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final String point in points)
                Chip(
                  label: Text(point, style: const TextStyle(fontSize: 12)),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
        ],

        // ---- 结果 ----
        if (_result != null) ...<Widget>[
          const SizedBox(height: 20),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              '已生成 ${_result!.count} 道变式题，保存为 ${_result!.fileName}\n'
              '可以在题库列表里找到它',
              style: TextStyle(
                fontSize: 13,
                color: colorScheme.onPrimaryContainer,
              ),
            ),
          ),
        ],
      ],
    );
  }

  String _stageText(VariantProgress progress) {
    return switch (progress.stage) {
      VariantStage.reading => '正在读取题库…',
      VariantStage.extracting => '正在归纳知识点…',
      VariantStage.generating =>
        progress.total > 0
            ? '正在重新出题：已完成 ${progress.finished} / ${progress.total} 道'
            : '正在重新出题…',
      VariantStage.saving => '正在写入 ${_targetFileName ?? ''}…',
    };
  }
}
