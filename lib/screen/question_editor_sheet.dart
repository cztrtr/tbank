import 'package:flutter/material.dart';

import '../models/question_bank.dart';

// -----------------------------------------------------------------------------
// 单题编辑表单
// -----------------------------------------------------------------------------

/// 题目编辑表单：题干、选项、答案、解析。
///
/// 以底部弹层形式出现，保存时通过 Navigator.pop 返回一个 map：
/// `{type, question, options, correctAnswer, analysis}`。
class QuestionEditorSheet extends StatefulWidget {
  const QuestionEditorSheet({super.key, this.initial, this.index});

  final Question? initial;
  final int? index;

  @override
  State<QuestionEditorSheet> createState() => _QuestionEditorSheetState();
}

class _QuestionEditorSheetState extends State<QuestionEditorSheet> {
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
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('第 ${i + 1} 个选项的标识和内容都要填')));
        return;
      }
      options.add(QuestionOption(key: key, text: text));
    }

    final List<String> answers;
    if (_isChoice) {
      if (options.isEmpty) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('选择题至少要有一个选项')));
        return;
      }
      if (_answerKeys.isEmpty) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('请点选正确答案')));
        return;
      }
      if (!_isMultiple && _answerKeys.length > 1) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('单选 / 判断只能有一个正确答案')));
        return;
      }
      final Set<String> keys = options.map((QuestionOption o) => o.key).toSet();
      answers = _answerKeys.where((String key) => keys.contains(key)).toList();
      if (answers.isEmpty) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('答案没有落在选项里')));
        return;
      }
    } else {
      answers = _answerText.text
          .split(RegExp(r'[\n;；]'))
          .map((String line) => line.trim())
          .where((String line) => line.isNotEmpty)
          .toList();
      if (answers.isEmpty) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('请填写参考答案')));
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
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
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
                        if (!_standardTypes.any(
                          (({String id, String label}) t) => t.id == _typeId,
                        ))
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
                                onSelected: (_) => _pickAnswer(key.text.trim()),
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
