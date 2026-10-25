// 练习页的完整生命周期：
// 1. 收到 QuestionBankFile 后，把源 json 复制到 App 文档目录；
// 2. 解析成 QuestionBank，逐题展示；
// 3. 每题判分后更新内存统计并写回工作副本；
// 4. 完成整份 / 进入后台 / 页面销毁时，把工作副本回拷到题库文件夹。
import 'dart:async';

import 'package:flutter/material.dart';

import '../models/question_bank.dart';
import '../models/question_bank_file.dart';
import '../services/question_bank_storage.dart';
import '../widgets/question_image.dart';

/// 练习页：加载题库、逐题作答、更新统计并回写文件。
///
/// 页面状态分三类：
/// - 加载态：_loading / _error / _questions；
/// - 当前题：_index / _selected / _showAnswer / _answered / _wasCorrect；
/// - 整份进度：_finished / _answeredCount / _correctCount / _syncMessage。
class PracticePage extends StatefulWidget {
  const PracticePage({super.key, this.bank});

  /// 从题库管理页选中的题库文件；null 表示还没选。
  final QuestionBankFile? bank;

  @override
  State<PracticePage> createState() => _PracticePageState();
}

class _PracticePageState extends State<PracticePage>
    with WidgetsBindingObserver {
  QuestionBankStorage? _storage; // 当前题库的文件读写器
  QuestionBank? _questions; // 已读进内存的题库

  bool _loading = false; // 是否正在加载题库
  String? _error; // 加载失败的提示

  int _index = 0; // 当前第几题（从 0 开始）
  final Set<String> _selected = <String>{}; // 选择题当前选中了哪些选项
  bool _showAnswer = false; // 填空/解释是否已展示答案
  bool _answered = false; // 当前题是否已经判定过
  bool _wasCorrect = false; // 当前题答得对不对
  bool _finished = false; // 整套题是否做完
  int _answeredCount = 0; // 本次练习一共答了多少题
  int _correctCount = 0; // 本次练习答对了多少题
  String? _syncMessage; // 回拷源文件的状态提示

  int _loadToken = 0; // 加载序号，防止旧加载覆盖新加载

  @override
  void initState() {
    super.initState();
    // 监听前后台切换，用于进入后台时回拷文件
    WidgetsBinding.instance.addObserver(this);

    final bank = widget.bank;
    if (bank != null) {
      unawaited(_loadBank(bank));
    }
  }

  @override
  void didUpdateWidget(covariant PracticePage oldWidget) {
    super.didUpdateWidget(oldWidget);

    // IndexedStack 会保留 State，换题库不会重跑 initState，只能在这里感知
    final bank = widget.bank;
    if (bank != null && oldWidget.bank?.uri != bank.uri) {
      unawaited(_loadBank(bank));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 进入后台、被系统回收前，把文档目录里的副本回拷到题库文件夹
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(_syncBack());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_syncBack()); // 页面销毁时再尝试同步一次
    super.dispose();
  }

  /// 打开题库：源文件复制到文档目录，再解析进内存。
  Future<void> _loadBank(QuestionBankFile file) async {
    // 切换题库前，先把上一个题库的改动同步回去，避免丢数据
    final previousStorage = _storage;
    if (previousStorage != null) {
      await previousStorage.syncBack();
    }
    if (!mounted) return;

    final token = ++_loadToken;

    setState(() {
      // 进入加载态，清空上一份题库的界面状态
      _loading = true;
      _error = null;
      _storage = null;
      _questions = null;
      _finished = false;
      _syncMessage = null;
      _index = 0;
      _answeredCount = 0;
      _correctCount = 0;
      _resetQuestionState();
    });

    try {
      final storage = QuestionBankStorage(file: file);
      final bank = await storage.load();

      // 页面已销毁，或又开始了新的加载：丢弃这次结果
      if (!mounted || token != _loadToken) return;

      setState(() {
        _storage = storage;
        _questions = bank;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || token != _loadToken) return;
      setState(() {
        _loading = false;
        _error = '读取题库失败：$error';
      });
    }
  }

  /// 重置“当前题”相关的临时状态，进入下一题时调用。
  void _resetQuestionState() {
    _selected.clear();
    _showAnswer = false;
    _answered = false;
    _wasCorrect = false;
  }

  /// 记录一次作答：更新内存统计，并立刻写一次工作副本。
  void _recordAnswer(bool correct) {
    if (_answered) return; // 防止同一题重复计数

    final bank = _questions;
    if (bank == null || _index >= bank.questions.length) return;

    final question = bank.questions[_index];
    question.stats.attemptCount += 1; // 答了一次
    if (!correct) {
      question.stats.wrongCount += 1; // 只有答错才累计错误数
    }

    setState(() {
      _answered = true;
      _wasCorrect = correct;
      _answeredCount += 1;
      if (correct) _correctCount += 1;
    });

    // 每答完一题就写一次文档目录下的副本，不做防抖
    unawaited(_persist());
  }

  /// 把当前题库写回文档目录下的工作副本。
  ///
  /// 每题判分后调用；实际写入由 QuestionBankStorage 的串行队列保证顺序。
  Future<void> _persist() async {
    final storage = _storage;
    final bank = _questions;
    if (storage == null || bank == null) return;

    try {
      await storage.save(bank);
    } catch (error) {
      debugPrint('保存工作副本失败：$error');
    }
  }

  /// 把工作副本回拷到题库文件夹。
  Future<bool> _syncBack() async {
    final storage = _storage;
    if (storage == null) return false;

    try {
      return await storage.syncBack();
    } catch (error) {
      debugPrint('同步回题库文件夹失败：$error');
      return false;
    }
  }

  /// 选择题提交：选中的集合必须和正确答案完全一致。
  void _submitChoice() {
    final bank = _questions;
    if (bank == null) return;

    final question = bank.questions[_index];
    final correct = question.correctAnswers.length == _selected.length &&
        question.correctAnswers.every(_selected.contains);

    _recordAnswer(correct);
  }

  /// 下一题；已经是最后一题就进入完成页并回拷源文件。
  void _next() {
    final bank = _questions;
    if (bank == null) return;

    if (_index + 1 >= bank.questions.length) {
      setState(() => _finished = true);
      unawaited(_finishAndSync());
      return;
    }

    setState(() {
      _index += 1;
      _resetQuestionState();
    });
  }

  /// 整套题做完后的回拷，并把结果显示在完成页。
  Future<void> _finishAndSync() async {
    if (!mounted) return;
    setState(() => _syncMessage = '正在同步到题库文件夹…');

    final ok = await _syncBack();
    if (!mounted) return;

    setState(() {
      _syncMessage = ok ? '已同步到题库文件夹' : '同步失败，请检查题库文件夹的写入权限';
    });
  }

  /// 重新从第一题开始；统计不重置，因为题目统计是累计值。
  void _restart() {
    setState(() {
      _index = 0;
      _finished = false;
      _answeredCount = 0;
      _correctCount = 0;
      _syncMessage = null;
      _resetQuestionState();
    });
  }

  @override
  Widget build(BuildContext context) {
    final bank = widget.bank;

    // 标题直接用题库文件名，方便确认当前练的是哪一份。
    return Scaffold(
      appBar: AppBar(title: Text(bank?.name ?? '练习')),
      body: _buildBody(bank),
    );
  }

  /// 按“未选题库 / 加载中 / 加载失败 / 空题库 / 已完成 / 答题中”分支展示。
  Widget _buildBody(QuestionBankFile? file) {
    if (file == null) {
      return const Center(child: Text('请先在“题库管理”里选择一个题库'));
    }
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
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => _loadBank(file),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    final bank = _questions;
    if (bank == null || bank.questions.isEmpty) {
      return const Center(child: Text('这个题库里没有题目'));
    }
    if (_finished) {
      return _buildFinished(bank);
    }

    return _buildQuestion(bank, bank.questions[_index]);
  }

  /// 单题界面：题号、进度、题干、作答区、下一题按钮、判分结果。
  Widget _buildQuestion(QuestionBank bank, Question question) {
    final total = bank.questions.length;
    final colorScheme = Theme.of(context).colorScheme;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
      children: <Widget>[
        Row(
          children: <Widget>[
            Text('第 ${_index + 1} / $total 题'),
            const Spacer(),
            _TypeBadge(type: question.type),
          ],
        ),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(99),
          child: LinearProgressIndicator(
            value: (_index + 1) / total,
            minHeight: 6,
          ),
        ),
        const SizedBox(height: 14),
        // 题干上方的累计统计；判分后 setState 会立即刷新成最新值
        Row(
          children: <Widget>[
            Icon(
              Icons.query_stats,
              size: 16,
              color: colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                '本题已作答 ${question.stats.attemptCount} 次 · 答错 ${question.stats.wrongCount} 次',
                style: TextStyle(
                  fontSize: 12,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        Text(
          question.question,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                height: 1.5,
                fontWeight: FontWeight.w600,
              ),
        ),
        const SizedBox(height: 20),

        // 填空/解释走“展示答案 + 自己判断”，其余题型走选项。
        // 配图位置按题型区分：选择题放在选项下方，填空/解释题紧跟题干。
        if (question.isFillBlank)
          ...<Widget>[
            _buildQuestionImage(question),
            ..._buildFillBlank(question),
          ]
        else
          ...<Widget>[
            ..._buildChoices(question),
            _buildQuestionImage(question),
          ],

        if (_answered) ...<Widget>[
          // 已判分：「下一题」紧跟作答区，判分结果与解析依次排在它下面
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _next,
              child: Text(_index + 1 >= total ? '完成练习' : '下一题'),
            ),
          ),
          const SizedBox(height: 16),
          _buildResult(question),
          if (question.hasAnalysis) ...<Widget>[
            const SizedBox(height: 12),
            _buildAnalysis(question),
          ],
        ] else if (!question.isFillBlank) ...<Widget>[
          // 未判分的选择题：选中至少一项才能提交
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _selected.isEmpty ? null : _submitChoice,
              child: const Text('提交答案'),
            ),
          ),
        ],
      ],
    );
  }

  /// 题目配图；没有配图时返回零尺寸组件，不占任何布局空间。
  ///
  /// 路径基准是「源 JSON 所在目录」而不是工作副本目录：
  /// 文档目录里的副本只有一个 JSON，图片仍在题库文件夹里。
  Widget _buildQuestionImage(Question question) {
    if (!question.hasImage) {
      return const SizedBox.shrink();
    }

    return QuestionImage(
      fileName: question.image,
      directoryRef: _storage?.sourceDirectoryRef,
    );
  }

  /// 选择题选项；多选可切换，单选和判断只能留一个。
  List<Widget> _buildChoices(Question question) {
    return <Widget>[
      for (final option in question.options)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _OptionButton(
            option: option,
            selected: _selected.contains(option.key),
            answered: _answered,
            isCorrect: question.correctAnswers.contains(option.key),
            onTap: _answered
                ? null // 判分后禁止再改
                : () {
                    setState(() {
                      if (question.isMultipleChoice) {
                        // 多选：点一下选中，再点取消
                        if (!_selected.add(option.key)) {
                          _selected.remove(option.key);
                        }
                      } else {
                        // 单选与判断：清空后只保留当前项
                        _selected
                          ..clear()
                          ..add(option.key);
                      }
                    });
                  },
          ),
        ),
    ];
  }

  /// 填空/解释作答区：先展示答案，再让用户判断自己答对没有。
  List<Widget> _buildFillBlank(Question question) {
    return <Widget>[
      if (!_showAnswer)
        SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            onPressed:
                _answered ? null : () => setState(() => _showAnswer = true),
            child: const Text('展示答案'),
          ),
        )
      else ...<Widget>[
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text('参考答案', style: TextStyle(fontSize: 12)),
              const SizedBox(height: 6),
              SelectableText(
                question.correctAnswers.join('\n'),
                style: const TextStyle(fontSize: 16, height: 1.5),
              ),
            ],
          ),
        ),
        if (!_answered) ...<Widget>[
          // 用户自己点“答对了 / 答错了”，据此更新统计
          const SizedBox(height: 16),
          Row(
            children: <Widget>[
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _recordAnswer(false),
                  child: const Text('答错了'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: () => _recordAnswer(true),
                  child: const Text('答对了'),
                ),
              ),
            ],
          ),
        ],
      ],
    ];
  }

  /// 判分结果条：正确用主色容器，错误用错误色容器。
  Widget _buildResult(Question question) {
    final colorScheme = Theme.of(context).colorScheme;
    final background = _wasCorrect
        ? colorScheme.primaryContainer
        : colorScheme.errorContainer;
    final foreground = _wasCorrect
        ? colorScheme.onPrimaryContainer
        : colorScheme.onErrorContainer;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            _wasCorrect ? '回答正确' : '回答错误',
            style: TextStyle(fontWeight: FontWeight.w700, color: foreground),
          ),
          const SizedBox(height: 6),
          Text(
            '正确答案：${_answerText(question)}',
            style: TextStyle(color: foreground),
          ),
        ],
      ),
    );
  }

  /// 题目解析：无论答对答错都展示，用中性配色和判分结果条区分开。
  ///
  /// 没有解析（`analysis` 为空）时调用方不会插入这个组件。
  Widget _buildAnalysis(Question question) {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                Icons.lightbulb_outline,
                size: 16,
                color: colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Text(
                '解析',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SelectableText(
            question.analysis,
            style: const TextStyle(fontSize: 14, height: 1.6),
          ),
        ],
      ),
    );
  }

  /// 把正确答案转成适合展示的文字：选择题带上选项内容。
  String _answerText(Question question) {    if (question.isFillBlank) {
      return question.correctAnswers.join(' / ');
    }

    final texts = question.options
        .where((option) => question.correctAnswers.contains(option.key))
        .map((option) => '${option.key}. ${option.text}')
        .toList();

    return texts.isEmpty
        ? question.correctAnswers.join(' / ')
        : texts.join(' / ');
  }

  /// 完成页：本次成绩 + 回拷状态 + 再练一遍。
  Widget _buildFinished(QuestionBank bank) {
    final colorScheme = Theme.of(context).colorScheme;

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
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 10),
            Text(
              '共 ${bank.questions.length} 题，本次作答 $_answeredCount 题，答对 $_correctCount 题',
              textAlign: TextAlign.center,
            ),
            if (_syncMessage != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                _syncMessage!,
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
                onPressed: _restart,
                child: const Text('再练一遍'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 题型标签：单选 / 多选 / 判断 / 填空·简答。
class _TypeBadge extends StatelessWidget {
  const _TypeBadge({required this.type});

  final QuestionType type;

  String get _label {
    switch (type) {
      case QuestionType.singleChoice:
        return '单选';
      case QuestionType.multipleChoice:
        return '多选';
      case QuestionType.trueFalse:
        return '判断';
      case QuestionType.fillBlank:
        return '填空/简答';
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(
        _label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: colorScheme.onSecondaryContainer,
        ),
      ),
    );
  }
}

/// 选项按钮：未作答、已选中、答对、答错分别用不同颜色表示。
class _OptionButton extends StatelessWidget {
  const _OptionButton({
    required this.option,
    required this.selected,
    required this.answered,
    required this.isCorrect,
    required this.onTap,
  });

  final QuestionOption option;
  final bool selected; // 用户是否选中了这一项
  final bool answered; // 本题是否已判分
  final bool isCorrect; // 这一项是否是正确答案
  final VoidCallback? onTap; // 判分后传 null，禁止再点

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    // 默认样式
    Color border = colorScheme.outlineVariant;
    Color background = colorScheme.surface;
    Color foreground = colorScheme.onSurface;

    if (answered) {
      // 判分后：正确项高亮主色，选错的项高亮错误色
      if (isCorrect) {
        border = colorScheme.primary;
        background = colorScheme.primaryContainer;
        foreground = colorScheme.onPrimaryContainer;
      } else if (selected) {
        border = colorScheme.error;
        background = colorScheme.errorContainer;
        foreground = colorScheme.onErrorContainer;
      }
    } else if (selected) {
      // 作答前：选中的项用主色边框和浅色底
      border = colorScheme.primary;
      background = colorScheme.primary.withValues(alpha: 0.08);
      foreground = colorScheme.primary;
    }

    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: border),
        ),
        child: Row(
          children: <Widget>[
            // 左侧字母圆标：A/B/C/D
            Container(
              width: 28,
              height: 28,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected || (answered && isCorrect)
                    ? border
                    : colorScheme.surfaceContainerHighest,
              ),
              child: Text(
                option.key,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: selected || (answered && isCorrect)
                      ? colorScheme.surface
                      : colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(option.text, style: TextStyle(color: foreground)),
            ),
            // 判分后右侧显示勾或叉
            if (answered && isCorrect)
              Icon(Icons.check, size: 20, color: colorScheme.primary)
            else if (answered && selected && !isCorrect)
              Icon(Icons.close, size: 20, color: colorScheme.error),
          ],
        ),
      ),
    );
  }
}
