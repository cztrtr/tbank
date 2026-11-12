// AI 题库的题目管理器：增删改查 + 重新出题 / 纠正错误。
//
// 入口有两个：
// - 管理页题库列表右侧的「编辑题目」按钮；
// - AI 出题页每本题库后面的「管理」按钮。
//
// 文件读写统一走 BankIo，所以 Android 的 SAF 目录和桌面普通路径都能编辑。
// 每次改动立即落盘，不做额外的「保存」按钮，避免用户忘记保存丢内容。
import 'package:flutter/material.dart';

import '../models/question_bank.dart';
import '../models/question_bank_file.dart';
import '../services/app_config.dart';
import '../services/bank_io.dart';
import '../services/ds_api_exception.dart';
import '../services/question_editor_ai.dart';
import '../widgets/math_text.dart';

/// 题目管理页。
class AiBankEditorPage extends StatefulWidget {
  const AiBankEditorPage({super.key, required this.file});

  /// 要编辑的题库文件；AI 出的题和用户自己的题库都能打开。
  final QuestionBankFile file;

  @override
  State<AiBankEditorPage> createState() => _AiBankEditorPageState();
}

class _AiBankEditorPageState extends State<AiBankEditorPage> {
  bool _loading = true;
  String? _error;

  /// 内存里的题目列表；改动后立即写回文件。
  List<Question> _questions = <Question>[];
  String? _plugin;
  int? _pluginVersion;

  /// 多选模式与选中的题号。
  bool _selecting = false;
  final Set<int> _selected = <int>{};

  /// AI 动作进行中的提示文本；null 表示空闲。
  String? _aiBusy;

  String get _topic =>
      (widget.file.directoryName ?? '').trim().isEmpty
          ? widget.file.displayName
          : widget.file.directoryName!;

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
      final QuestionBank bank = QuestionCodec.decode(
        await BankIo.readText(widget.file.uri),
      );
      if (!mounted) return;
      setState(() {
        _questions = List<Question>.of(bank.questions);
        _plugin = bank.plugin;
        _pluginVersion = bank.pluginVersion;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '读取题库失败：$error';
      });
    }
  }

  /// 把当前题目列表写回文件。
  Future<bool> _persist() async {
    try {
      final String text = QuestionCodec.encode(
        QuestionBank(
          questions: _questions,
          plugin: _plugin,
          pluginVersion: _pluginVersion,
        ),
      );
      await BankIo.writeText(widget.file.uri, text);
      return true;
    } catch (error) {
      if (mounted) _toast('保存失败：$error');
      return false;
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  void _exitSelecting() {
    setState(() {
      _selecting = false;
      _selected.clear();
    });
  }

  void _toggleSelected(int index) {
    setState(() {
      if (!_selected.remove(index)) _selected.add(index);
    });
  }

  // ---------------------------------------------------------------------------
  // 单题编辑
  // ---------------------------------------------------------------------------

  /// 打开编辑表单；新增时 [index] 为 null。
  Future<void> _openEditor(int? index) async {
    final Question? origin = index == null ? null : _questions[index];
    final Map<String, dynamic>? result =
        await showModalBottomSheet<Map<String, dynamic>>(
          context: context,
          isScrollControlled: true,
          useSafeArea: true,
          builder: (BuildContext sheetContext) => _QuestionEditorSheet(
            initial: origin,
            index: index,
          ),
        );
    if (!mounted || result == null) return;

    final Question next = _buildQuestion(origin, result);
    setState(() {
      if (index == null) {
        _questions = <Question>[..._questions, next];
      } else {
        _questions = List<Question>.of(_questions)..[index] = next;
      }
    });
    await _persist();
    if (mounted) _toast(index == null ? '已新增题目' : '已保存修改');
  }

  /// 生成一个没被占用的题目 id。
  ///
  /// 不能直接用「题目数 + 1」：删掉中间的题之后，那个 id 还留在文件里，
  /// 再加题就会撞号 —— 断点续练靠 id 序列匹配，撞号会让进度错位。
  String _nextQuestionId() {
    int max = 0;
    final RegExp pattern = RegExp(r'(\d+)\s*$');
    for (final Question question in _questions) {
      final RegExpMatch? match = pattern.firstMatch(question.id.trim());
      if (match == null) continue;
      final int value = int.tryParse(match.group(1)!) ?? 0;
      if (value > max) max = value;
    }
    return 'Q${(max + 1).toString().padLeft(3, '0')}';
  }

  /// 用编辑结果重建 [Question]，保留 id、统计、错题本标记等运行态字段。
  ///
  /// [data] 可能是两种来源：
  /// - 编辑表单返回的 [QuestionOption] 列表；
  /// - AI 返回的题目 JSON（options 是 `[{key, text}]` 的 map 列表）。
  /// 所以这里统一按「宽松解析」处理，不做泛型强转。
  Question _buildQuestion(
    Question? origin,
    Map<String, dynamic> data,
  ) {
    final String typeId =
        (data['type'] as String?)?.trim().isNotEmpty == true
            ? data['type'] as String
            : QuestionType.fillBlank.value;

    return Question(
      id: origin?.id ?? _nextQuestionId(),
      type: QuestionCodec.parseType(typeId),
      typeId: typeId,
      question: (data['question'] as String?)?.trim() ?? '',
      image: origin?.image ?? '',
      options: _parseOptions(data['options']),
      correctAnswers: _parseAnswers(data['correctAnswer']),
      analysis: (data['analysis'] as String?)?.trim() ?? '',
      stats: origin?.stats ?? QuestionStats(),
      origin: origin?.origin,
      mistakeScore: origin?.mistakeScore,
      pluginData: origin?.pluginData,
    );
  }

  /// 把 options 解析成 [QuestionOption] 列表。
  ///
  /// 同时接受 `QuestionOption` 对象和 `{key, text}` 形式的 map：
  /// 编辑表单给的是前者，AI 返回的是后者。缺 key 或 text 的项直接跳过。
  static List<QuestionOption> _parseOptions(dynamic raw) {
    final List<QuestionOption> options = <QuestionOption>[];
    if (raw is! List) return options;

    for (final dynamic item in raw) {
      if (item is QuestionOption) {
        if (item.key.trim().isNotEmpty && item.text.trim().isNotEmpty) {
          options.add(item);
        }
        continue;
      }
      if (item is Map) {
        final String key = (item['key']?.toString() ?? '').trim();
        final String text = (item['text']?.toString() ?? '').trim();
        if (key.isNotEmpty && text.isNotEmpty) {
          options.add(QuestionOption(key: key, text: text));
        }
      }
    }
    return options;
  }

  /// 把 correctAnswer 解析成字符串列表。
  ///
  /// 兼容数组和单个字符串两种写法；空串自动丢掉。
  static List<String> _parseAnswers(dynamic raw) {
    if (raw is List) {
      return raw
          .map((dynamic item) => item?.toString().trim() ?? '')
          .where((String value) => value.isNotEmpty)
          .toList();
    }
    if (raw is String && raw.trim().isNotEmpty) {
      return <String>[raw.trim()];
    }
    return <String>[];
  }

  // ---------------------------------------------------------------------------
  // 删除
  // ---------------------------------------------------------------------------

  Future<void> _deleteIndices(Set<int> indices) async {
    if (indices.isEmpty) return;

    final bool ok = await _confirm(
      '删除 ${indices.length} 道题？',
      '删除后无法恢复，题库文件会立即更新。',
    );
    if (!ok || !mounted) return;

    final List<int> ordered = indices.toList()..sort((int a, int b) => b - a);
    setState(() {
      final List<Question> next = List<Question>.of(_questions);
      for (final int index in ordered) {
        if (index >= 0 && index < next.length) next.removeAt(index);
      }
      _questions = next;
      _selecting = false;
      _selected.clear();
    });
    await _persist();
    if (mounted) _toast('已删除 ${ordered.length} 道题');
  }

  Future<bool> _confirm(String title, String message) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  // ---------------------------------------------------------------------------
  // AI 重新出题 / 纠正错误
  // ---------------------------------------------------------------------------

  /// 点「重新出题 / 纠正错误」的入口：先问用户想往哪个方向改，再开跑。
  ///
  /// 返回 null 表示用户取消了；返回空串表示「没想法，让 AI 自己发挥」。
  Future<void> _startAi(Set<int> indices, {required bool fix}) async {
    if (indices.isEmpty || _aiBusy != null) return;

    if ((AppConfig.dsApiKey ?? '').trim().isEmpty) {
      _toast('请先到 设置 里填写 DeepSeek API Key');
      return;
    }

    final String? guidance = await showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) =>
          _GuidanceDialog(fix: fix, count: indices.length),
    );
    if (!mounted || guidance == null) return; // 取消
    await _runAi(indices, fix: fix, guidance: guidance);
  }

  /// 对选中的题调用 AI。
  ///
  /// [fix] 为 true 是「纠正错误」，false 是「重新出题」；
  /// [guidance] 是用户填的方向 / 重点，空串表示不额外提要求。
  Future<void> _runAi(
    Set<int> indices, {
    required bool fix,
    String guidance = '',
  }) async {
    if (indices.isEmpty || _aiBusy != null) return;

    final List<int> ordered = indices.toList()..sort();
    int done = 0;
    int failed = 0;

    for (final int index in ordered) {
      if (!mounted) return;
      setState(() {
        _aiBusy = '${fix ? '纠正错误' : '重新出题'}：'
            '${done + 1} / ${ordered.length}';
      });

      final Question origin = _questions[index];
      try {
        final Map<String, dynamic> data = await QuestionEditorAi.rewrite(
          origin,
          topic: _topic,
          fix: fix,
          guidance: guidance,
        );
        // 保留 id / 统计，只换题干、选项、答案和解析
        final Question next = _buildQuestion(origin, data);
        if (!mounted) return;
        setState(() {
          _questions = List<Question>.of(_questions)..[index] = next;
        });
      } on DsApiException catch (error) {
        failed++;
        if (mounted) _toast('第 ${index + 1} 题失败：${error.message}');
      } catch (error) {
        failed++;
        if (mounted) _toast('第 ${index + 1} 题失败：$error');
      }
      done++;
    }

    if (!mounted) return;
    setState(() => _aiBusy = null);
    final bool saved = await _persist();
    if (!mounted) return;

    setState(() {
      _selecting = false;
      _selected.clear();
    });
    if (saved) {
      _toast(
        failed == 0
            ? '已完成 $done 道题'
            : '完成 $done 道，其中 $failed 道失败',
      );
    }
  }

  // ---------------------------------------------------------------------------
  // 界面
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: _selecting
            ? Text('已选 ${_selected.length} 题')
            : Text(widget.file.displayName),
        leading: _selecting
            ? IconButton(
                icon: const Icon(Icons.close),
                tooltip: '退出多选',
                onPressed: _exitSelecting,
              )
            : null,
        actions: <Widget>[
          if (!_loading && _error == null)
            IconButton(
              tooltip: _selecting ? '退出多选' : '批量选择',
              onPressed: () {
                setState(() {
                  _selecting = !_selecting;
                  _selected.clear();
                });
              },
              icon: Icon(_selecting ? Icons.done : Icons.checklist),
            ),
        ],
      ),
      floatingActionButton: _loading || _error != null
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _openEditor(null),
              icon: const Icon(Icons.add),
              label: const Text('新增题目'),
            ),
      bottomNavigationBar: _selecting ? _buildActionBar(colors) : null,
      body: _buildBody(colors),
    );
  }

  Widget _buildBody(ColorScheme colors) {
    if (_loading) return const Center(child: CircularProgressIndicator());

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(onPressed: _load, child: const Text('重试')),
            ],
          ),
        ),
      );
    }

    if (_questions.isEmpty) {
      return const Center(child: Text('这本题库还没有题目，点右下角新增'));
    }

    return Column(
      children: <Widget>[
        if (_aiBusy != null)
          Container(
            width: double.infinity,
            color: colors.primaryContainer,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: <Widget>[
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _aiBusy!,
                    style: TextStyle(
                      fontSize: 13,
                      color: colors.onPrimaryContainer,
                    ),
                  ),
                ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '共 ${_questions.length} 题 · $_topic · 改动立即保存',
              style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
            ),
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 96),
            itemCount: _questions.length,
            itemBuilder: (BuildContext context, int index) =>
                _buildCard(colors, index),
          ),
        ),
      ],
    );
  }

  Widget _buildCard(ColorScheme colors, int index) {
    final Question question = _questions[index];
    final bool isSelected = _selected.contains(index);

    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      color: isSelected ? colors.primaryContainer : colors.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: isSelected ? colors.primary : colors.outlineVariant,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: _aiBusy != null
            ? null
            : () {
                if (_selecting) {
                  _toggleSelected(index);
                } else {
                  _openEditor(index);
                }
              },
        onLongPress: _aiBusy != null
            ? null
            : () {
                setState(() => _selecting = true);
                _toggleSelected(index);
              },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (_selecting)
                Padding(
                  padding: const EdgeInsets.only(top: 2, right: 4),
                  child: Icon(
                    isSelected
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
                    size: 20,
                    color: isSelected ? colors.primary : colors.outline,
                  ),
                ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Text(
                          '${index + 1}',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: colors.primary,
                          ),
                        ),
                        const SizedBox(width: 8),
                        _TypeChip(typeId: question.typeId),
                        const SizedBox(width: 6),
                        if (!question.hasAnalysis)
                          _HintChip(
                            text: '无解析',
                            color: colors.error,
                          ),
                        if (question.correctAnswers.isEmpty)
                          _HintChip(
                            text: '缺答案',
                            color: colors.error,
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    // 题干 / 答案都可能是 LaTeX，按公式渲染，别让用户看源码
                    MathText(
                      question.question,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14, height: 1.4),
                    ),
                    if (question.correctAnswers.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 4),
                      MathText(
                        '答案：${question.correctAnswers.join(' / ')}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (!_selecting)
                PopupMenuButton<String>(
                  enabled: _aiBusy == null,
                  icon: const Icon(Icons.more_vert, size: 20),
                  onSelected: (String action) {
                    switch (action) {
                      case 'edit':
                        _openEditor(index);
                      case 'regen':
                        _startAi(<int>{index}, fix: false);
                      case 'fix':
                        _startAi(<int>{index}, fix: true);
                      case 'delete':
                        _deleteIndices(<int>{index});
                    }
                  },
                  itemBuilder: (BuildContext context) =>
                      const <PopupMenuEntry<String>>[
                        PopupMenuItem<String>(
                          value: 'edit',
                          child: Text('编辑题目'),
                        ),
                        PopupMenuItem<String>(
                          value: 'regen',
                          child: Text('重新出题'),
                        ),
                        PopupMenuItem<String>(
                          value: 'fix',
                          child: Text('纠正错误'),
                        ),
                        PopupMenuItem<String>(
                          value: 'delete',
                          child: Text('删除'),
                        ),
                      ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 多选模式下的底部操作栏。
  Widget _buildActionBar(ColorScheme colors) {
    final bool idle = _selected.isEmpty || _aiBusy != null;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Row(
          children: <Widget>[
            Expanded(
              child: OutlinedButton.icon(
                onPressed: idle
                    ? null
                    : () => _startAi(_selected, fix: false),
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('重新出题'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: idle ? null : () => _startAi(_selected, fix: true),
                icon: const Icon(Icons.fact_check_outlined, size: 18),
                label: const Text('纠正错误'),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filledTonal(
              tooltip: '删除选中题目',
              onPressed: idle ? null : () => _deleteIndices(_selected),
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// 小部件
// -----------------------------------------------------------------------------

/// 题型标签：标准题型显示中文，插件题型显示原始 id。
class _TypeChip extends StatelessWidget {
  const _TypeChip({required this.typeId});

  final String typeId;

  @override
  Widget build(BuildContext context) {
    const Map<String, String> labels = <String, String>{
      'single_choice': '单选',
      'multiple_choice': '多选',
      'true_false': '判断',
      'fill_blank': '填空/简答',
    };
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: colors.secondaryContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        labels[typeId] ?? typeId,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: colors.onSecondaryContainer,
        ),
      ),
    );
  }
}

class _HintChip extends StatelessWidget {
  const _HintChip({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: color.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(text, style: TextStyle(fontSize: 10, color: color)),
    );
  }
}

// -----------------------------------------------------------------------------
// 「重新出题 / 纠正错误」的方向输入
// -----------------------------------------------------------------------------

/// 让用户先说明想让 AI 往哪个方向改，再开跑。
///
/// 返回用户填的文字（可能为空串，表示让 AI 自己发挥）；点取消返回 null。
class _GuidanceDialog extends StatefulWidget {
  const _GuidanceDialog({required this.fix, required this.count});

  /// true 是「纠正错误」，false 是「重新出题」。
  final bool fix;

  /// 本次要处理的题目数量，多题时提示会应用到哪里。
  final int count;

  @override
  State<_GuidanceDialog> createState() => _GuidanceDialogState();
}

class _GuidanceDialogState extends State<_GuidanceDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final bool fix = widget.fix;

    return AlertDialog(
      title: Text(fix ? '纠正错误' : '重新出题'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            fix
                ? 'AI 会核对这道题的答案和解析。想重点看哪一块？'
                : 'AI 会围绕同一个知识点换一道新题。想朝哪个方向出？',
            style: const TextStyle(fontSize: 13, height: 1.5),
          ),
          if (widget.count > 1) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              '同一方向会应用到选中的 ${widget.count} 道题',
              style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
            ),
          ],
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            autofocus: true,
            minLines: 2,
            maxLines: 4,
            textInputAction: TextInputAction.newline,
            decoration: InputDecoration(
              hintText: fix
                  ? '如：重点核对选项 D 是否正确 / 解析里的符号推导'
                  : '如：改成应用题、降低难度、换成具体数值、加大计算量',
              hintStyle: const TextStyle(fontSize: 13),
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '留空就直接开始，让 AI 自己判断。',
            style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          child: const Text('开始'),
        ),
      ],
    );
  }
}

// -----------------------------------------------------------------------------
// 单题编辑表单
// -----------------------------------------------------------------------------

/// 题目编辑表单：题干、选项、答案、解析。
///
/// 以底部弹层形式出现，保存时通过 Navigator.pop 返回一个 map：
/// `{type, question, options, correctAnswer, analysis}`。
class _QuestionEditorSheet extends StatefulWidget {
  const _QuestionEditorSheet({this.initial, this.index});

  final Question? initial;
  final int? index;

  @override
  State<_QuestionEditorSheet> createState() => _QuestionEditorSheetState();
}

class _QuestionEditorSheetState extends State<_QuestionEditorSheet> {
  static const List<({String id, String label})> _standardTypes =
      <({String id, String label})>[
        (id: 'single_choice', label: '单选'),
        (id: 'multiple_choice', label: '多选'),
        (id: 'true_false', label: '判断'),
        (id: 'fill_blank', label: '填空 / 简答'),
      ];

  late final TextEditingController _question;
  late final TextEditingController _analysis;
  late final TextEditingController _answerText;
  late final List<TextEditingController> _optionKeys;
  late final List<TextEditingController> _optionTexts;
  late String _typeId;
  late final Set<String> _answerKeys;

  @override
  void initState() {
    super.initState();
    final Question? origin = widget.initial;
    _typeId = origin?.typeId ?? 'single_choice';
    _question = TextEditingController(text: origin?.question ?? '');
    _analysis = TextEditingController(text: origin?.analysis ?? '');
    _optionKeys = <TextEditingController>[];
    _optionTexts = <TextEditingController>[];
    _answerKeys = <String>{};

    final List<QuestionOption> options = origin?.options ?? <QuestionOption>[];
    for (final QuestionOption option in options) {
      _optionKeys.add(TextEditingController(text: option.key));
      _optionTexts.add(TextEditingController(text: option.text));
    }
    if (_optionKeys.isEmpty && _typeId != 'fill_blank') {
      for (final String key in const <String>['A', 'B', 'C', 'D']) {
        _optionKeys.add(TextEditingController(text: key));
        _optionTexts.add(TextEditingController(text: ''));
      }
    }

    // 选择题：答案就是选项 key；主观题：答案是文本
    if (_isChoice) {
      for (final String answer in origin?.correctAnswers ?? <String>[]) {
        _answerKeys.add(answer.trim());
      }
      _answerText = TextEditingController();
    } else {
      _answerText = TextEditingController(
        text: (origin?.correctAnswers ?? <String>[]).join('\n'),
      );
    }
  }

  @override
  void dispose() {
    _question.dispose();
    _analysis.dispose();
    _answerText.dispose();
    for (final TextEditingController controller in _optionKeys) {
      controller.dispose();
    }
    for (final TextEditingController controller in _optionTexts) {
      controller.dispose();
    }
    super.dispose();
  }

  bool get _isChoice =>
      _typeId == 'single_choice' ||
      _typeId == 'multiple_choice' ||
      _typeId == 'true_false';

  bool get _isMultiple => _typeId == 'multiple_choice';

  /// 切换题型时补齐/隐藏选项，并清掉不再适用的答案。
  void _changeType(String typeId) {
    setState(() {
      final bool wasChoice = _isChoice;
      _typeId = typeId;
      _answerKeys.clear();

      if (_isChoice && !wasChoice) {
        // 从主观题切回来：没有选项就补四个空位
        if (_optionKeys.isEmpty) {
          for (final String key in const <String>['A', 'B', 'C', 'D']) {
            _optionKeys.add(TextEditingController(text: key));
            _optionTexts.add(TextEditingController(text: ''));
          }
        }
      }
      if (_isChoice) _answerText.text = '';
    });
  }

  void _addOption() {
    setState(() {
      final int index = _optionKeys.length;
      _optionKeys.add(
        TextEditingController(text: String.fromCharCode(65 + index % 26)),
      );
      _optionTexts.add(TextEditingController(text: ''));
    });
  }

  void _removeOption(int index) {
    setState(() {
      _answerKeys.remove(_optionKeys[index].text.trim());
      _optionKeys.removeAt(index).dispose();
      _optionTexts.removeAt(index).dispose();
    });
  }

  /// 选择题点选答案：单选/判断只留一个，多选可切多个。
  void _pickAnswer(String key) {
    setState(() {
      if (_isMultiple) {
        if (!_answerKeys.add(key)) _answerKeys.remove(key);
      } else {
        _answerKeys
          ..clear()
          ..add(key);
      }
    });
  }

  void _submit() {
    final String stem = _question.text.trim();
    if (stem.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('题干不能为空')));
      return;
    }

    final List<QuestionOption> options = <QuestionOption>[];
    for (int i = 0; i < _optionKeys.length; i++) {
      final String key = _optionKeys[i].text.trim();
      final String text = _optionTexts[i].text.trim();
      if (key.isEmpty && text.isEmpty) continue; // 空行直接忽略
      if (key.isEmpty || text.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('第 ${i + 1} 个选项的标识和内容都要填')),
        );
        return;
      }
      options.add(QuestionOption(key: key, text: text));
    }

    final List<String> answers;
    if (_isChoice) {
      if (options.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('选择题至少要有一个选项')),
        );
        return;
      }
      if (_answerKeys.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请点选正确答案')),
        );
        return;
      }
      if (!_isMultiple && _answerKeys.length > 1) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('单选 / 判断只能有一个正确答案')),
        );
        return;
      }
      final Set<String> keys =
          options.map((QuestionOption o) => o.key).toSet();
      answers = _answerKeys
          .where((String key) => keys.contains(key))
          .toList();
      if (answers.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('答案没有落在选项里')),
        );
        return;
      }
    } else {
      answers = _answerText.text
          .split(RegExp(r'[\n;；]'))
          .map((String line) => line.trim())
          .where((String line) => line.isNotEmpty)
          .toList();
      if (answers.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请填写参考答案')),
        );
        return;
      }
    }

    Navigator.pop(context, <String, dynamic>{
      'type': _typeId,
      'question': stem,
      'options': options,
      'correctAnswer': answers,
      'analysis': _analysis.text.trim(),
    });
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final String title = widget.index == null
        ? '新增题目'
        : '编辑第 ${widget.index! + 1} 题';

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: DraggableScrollableSheet(
        initialChildSize: 0.9,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (BuildContext context, ScrollController controller) {
          return Column(
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        title,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('取消'),
                    ),
                    FilledButton(onPressed: _submit, child: const Text('保存')),
                    const SizedBox(width: 4),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView(
                  controller: controller,
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                  children: <Widget>[
                    // 题型
                    DropdownButtonFormField<String>(
                      initialValue: _typeId,
                      decoration: const InputDecoration(
                        labelText: '题型',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      items: <DropdownMenuItem<String>>[
                        for (final ({String id, String label}) type
                            in _standardTypes)
                          DropdownMenuItem<String>(
                            value: type.id,
                            child: Text(type.label),
                          ),
                        // 插件自定义题型：只展示，不改
                        if (!_standardTypes
                            .any((({String id, String label}) t) =>
                                t.id == _typeId))
                          DropdownMenuItem<String>(
                            value: _typeId,
                            child: Text('$_typeId（插件题型）'),
                          ),
                      ],
                      onChanged: (String? value) {
                        if (value != null) _changeType(value);
                      },
                    ),
                    const SizedBox(height: 14),

                    // 题干
                    TextField(
                      controller: _question,
                      minLines: 3,
                      maxLines: 8,
                      decoration: const InputDecoration(
                        labelText: '题干',
                        hintText: '支持 LaTeX，行内用 \$...\$',
                        alignLabelWithHint: true,
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 14),

                    // 选项
                    if (_isChoice) ...<Widget>[
                      Row(
                        children: <Widget>[
                          const Text(
                            '选项',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                          const Spacer(),
                          TextButton.icon(
                            onPressed: _addOption,
                            icon: const Icon(Icons.add, size: 18),
                            label: const Text('添加'),
                          ),
                        ],
                      ),
                      for (int i = 0; i < _optionKeys.length; i++)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Row(
                            children: <Widget>[
                              SizedBox(
                                width: 56,
                                child: TextField(
                                  controller: _optionKeys[i],
                                  textAlign: TextAlign.center,
                                  decoration: const InputDecoration(
                                    isDense: true,
                                    border: OutlineInputBorder(),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: TextField(
                                  controller: _optionTexts[i],
                                  minLines: 1,
                                  maxLines: 3,
                                  decoration: const InputDecoration(
                                    isDense: true,
                                    hintText: '选项内容',
                                    border: OutlineInputBorder(),
                                  ),
                                ),
                              ),
                              IconButton(
                                tooltip: '删除这个选项',
                                onPressed: () => _removeOption(i),
                                icon: Icon(
                                  Icons.remove_circle_outline,
                                  size: 20,
                                  color: colors.error,
                                ),
                              ),
                            ],
                          ),
                        ),
                      const SizedBox(height: 6),

                      // 答案
                      Text(
                        _isMultiple ? '正确答案（可多选）' : '正确答案',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: <Widget>[
                          for (final TextEditingController key in _optionKeys)
                            if (key.text.trim().isNotEmpty)
                              FilterChip(
                                label: Text(key.text.trim()),
                                selected: _answerKeys.contains(key.text.trim()),
                                onSelected: (_) =>
                                    _pickAnswer(key.text.trim()),
                              ),
                        ],
                      ),
                    ] else ...<Widget>[
                      TextField(
                        controller: _answerText,
                        minLines: 3,
                        maxLines: 8,
                        decoration: const InputDecoration(
                          labelText: '参考答案',
                          hintText: '每行一个答案；判分时按语义比对',
                          alignLabelWithHint: true,
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ],
                    const SizedBox(height: 14),

                    // 解析
                    TextField(
                      controller: _analysis,
                      minLines: 2,
                      maxLines: 8,
                      decoration: const InputDecoration(
                        labelText: '解析（可留空）',
                        alignLabelWithHint: true,
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
