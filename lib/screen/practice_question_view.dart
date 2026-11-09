import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/question_bank.dart';
import '../widgets/math_text.dart';
import '../widgets/question_image.dart';
import 'answer_image_picker.dart';

/// 单题视图：题干、配图、选项/输入区、判分结果、解析、AI 解析。
///
/// 从 PracticePage 里拆出来以后，这里只负责渲染和把用户操作回调给页面；
/// 答题状态、AI 请求、保存/回拷仍在页面和对应 service 里。
class PracticeQuestionView extends StatelessWidget {
  const PracticeQuestionView({
    super.key,
    required this.question,
    required this.index,
    required this.total,
    required this.selected,
    required this.answered,
    required this.wasCorrect,
    required this.showAnswer,
    required this.grading,
    required this.aiEnabled,
    required this.aiScore,
    required this.aiAnalysisLoading,
    required this.aiAnalysis,
    required this.aiAnalysisError,
    required this.answerController,
    required this.answerImages,
    required this.correctAnswerText,
    required this.sourceDirectoryRef,
    required this.onSelectOption,
    required this.onSubmitChoice,
    required this.onSubmitAi,
    required this.onShowAnswer,
    required this.onSelfJudge,
    required this.onAnswerChanged,
    required this.onPickImage,
    required this.onRemoveImage,
    required this.onRequestAiAnalysis,
    required this.onNext,
    required this.onPrevious,
  });

  final Question question;
  final int index;
  final int total;
  final Set<String> selected;
  final bool answered;
  final bool wasCorrect;
  final bool showAnswer;
  final bool grading;
  final bool aiEnabled;
  final int? aiScore;
  final bool aiAnalysisLoading;
  final String? aiAnalysis;
  final String? aiAnalysisError;
  final TextEditingController answerController;
  final List<Uint8List> answerImages;
  final String correctAnswerText;
  final String? sourceDirectoryRef;

  final ValueChanged<String> onSelectOption;
  final VoidCallback onSubmitChoice;
  final VoidCallback onSubmitAi;
  final VoidCallback onShowAnswer;
  final ValueChanged<bool> onSelfJudge;
  final VoidCallback onAnswerChanged;
  final VoidCallback onPickImage;
  final ValueChanged<int> onRemoveImage;
  final VoidCallback onRequestAiAnalysis;
  final VoidCallback onNext;
  final VoidCallback onPrevious;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
      children: <Widget>[
        Row(
          children: <Widget>[
            Text('第 ${index + 1} / $total 题'),
            const Spacer(),
            _TypeBadge(type: question.type),
          ],
        ),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(99),
          child: LinearProgressIndicator(
            value: (index + 1) / total,
            minHeight: 6,
          ),
        ),
        const SizedBox(height: 14),
        // 题干上方的累计统计；判分后页面 setState 会立即刷新成最新值
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
        MathText(
          question.question,
          style: Theme.of(context).textTheme.titleMedium
              ?.copyWith(height: 1.5, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 20),

        // 填空/解释走“展示答案 + 自己判断”，其余题型走选项。
        // 配图位置按题型区分：选择题放在选项下方，填空/解释题紧跟题干。
        if (question.isFillBlank) ...<Widget>[
          _buildQuestionImage(),
          ..._buildFillBlank(context),
        ] else ...<Widget>[..._buildChoices(), _buildQuestionImage()],

        if (answered) ...<Widget>[
          // 已判分：底部「下一题」占满一行
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: onNext,
              child: Text(index + 1 >= total ? '完成练习' : '下一题'),
            ),
          ),
          // AI 解析按钮紧贴判分结果上方，保证一定在视口里
          const SizedBox(height: 12),
          ..._buildAiAnalysisEntry(context),
          const SizedBox(height: 16),
          _buildResult(context),
          if (question.hasAnalysis) ...<Widget>[
            const SizedBox(height: 12),
            _buildAnalysis(context),
          ],
        ] else if (!question.isFillBlank) ...<Widget>[
          // 未判分的选择题：左边「上一题」，右边「提交答案」
          const SizedBox(height: 16),
          Row(
            children: <Widget>[
              Expanded(
                child: OutlinedButton(
                  onPressed: index > 0 ? onPrevious : null,
                  child: const Text('上一题'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: selected.isEmpty ? null : onSubmitChoice,
                  child: const Text('提交答案'),
                ),
              ),
            ],
          ),
        ],

        // 主观题「展示答案」之后就能问 AI，不必先自判对错
        if (!answered && question.isFillBlank && showAnswer) ...<Widget>[
          const SizedBox(height: 12),
          ..._buildAiAnalysisEntry(context),
        ],
      ],
    );
  }

  /// 题目配图；没有配图时返回零尺寸组件，不占任何布局空间。
  Widget _buildQuestionImage() {
    if (!question.hasImage) return const SizedBox.shrink();

    return QuestionImage(
      fileName: question.image,
      directoryRef: sourceDirectoryRef,
    );
  }

  /// 选择题选项；多选可切换，单选和判断只能留一个。
  List<Widget> _buildChoices() {
    return <Widget>[
      for (final QuestionOption option in question.options)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _OptionButton(
            option: option,
            selected: selected.contains(option.key),
            answered: answered,
            isCorrect: question.correctAnswers.contains(option.key),
            onTap: answered ? null : () => onSelectOption(option.key),
          ),
        ),
    ];
  }

  /// 填空/解释作答区。
  ///
  /// 配了 DeepSeek API Key 时用 AI 判分；没配 Key 或本题判分失败时退回
  /// 「展示答案 + 自判」。
  List<Widget> _buildFillBlank(BuildContext context) {
    if (!aiEnabled) return _buildFillBlankManual(context);

    // 已判分：输入区收起，对错 / AI 得分 / 参考答案 / 解析由下方结果区展示
    if (answered) return <Widget>[];

    final bool canSubmit =
        !grading &&
        (answerController.text.trim().isNotEmpty || answerImages.isNotEmpty);

    return <Widget>[
      TextField(
        controller: answerController,
        minLines: 3,
        maxLines: null,
        enabled: !grading,
        onChanged: (_) => onAnswerChanged(),
        style: const TextStyle(fontSize: 15, height: 1.5),
        decoration: InputDecoration(
          hintText: '在这里输入你的答案（也可以只上传图片）',
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),

      // 已选图片的缩略图；没有图片时不占空间
      if (answerImages.isNotEmpty) ...<Widget>[
        const SizedBox(height: 12),
        _buildAnswerImages(),
      ],

      const SizedBox(height: 10),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          onPressed: grading ? null : onPickImage,
          icon: const Icon(Icons.add_a_photo_outlined, size: 18),
          label: Text(
            answerImages.isEmpty
                ? '拍照 / 上传作答图片'
                : '继续添加图片（${answerImages.length}/${AnswerImagePicker.maxImages}）',
          ),
        ),
      ),
      const SizedBox(height: 2),
      Text(
        '拍照上传手写作答，AI 会结合图片内容判分，最多 ${AnswerImagePicker.maxImages} 张',
        style: TextStyle(
          fontSize: 11,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: 12),

      // 左边「上一题」，右边「提交」（交给 AI 判分）
      Row(
        children: <Widget>[
          Expanded(
            child: OutlinedButton(
              onPressed: index > 0 ? onPrevious : null,
              child: const Text('上一题'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: FilledButton(
              onPressed: canSubmit ? onSubmitAi : null,
              child: grading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('提交'),
            ),
          ),
        ],
      ),
    ];
  }

  /// 没有可用 AI 时的老流程：先展示答案，再由用户自己判断对错。
  List<Widget> _buildFillBlankManual(BuildContext context) {
    return <Widget>[
      if (!showAnswer)
        // 左边「上一题」，右边「展示答案」
        Row(
          children: <Widget>[
            Expanded(
              child: OutlinedButton(
                onPressed: index > 0 ? onPrevious : null,
                child: const Text('上一题'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton(
                onPressed: answered ? null : onShowAnswer,
                child: const Text('展示答案'),
              ),
            ),
          ],
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
              MathText(
                question.correctAnswers.join('\n'),
                style: const TextStyle(fontSize: 16, height: 1.5),
                selectable: true,
              ),
            ],
          ),
        ),
        if (!answered) ...<Widget>[
          // 用户自己点“答对了 / 答错了”，据此更新统计
          const SizedBox(height: 16),
          Row(
            children: <Widget>[
              Expanded(
                child: OutlinedButton(
                  onPressed: () => onSelfJudge(false),
                  child: const Text('答错了'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: () => onSelfJudge(true),
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
  Widget _buildResult(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final Color background = wasCorrect
        ? colorScheme.primaryContainer
        : colorScheme.errorContainer;
    final Color foreground = wasCorrect
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
            wasCorrect ? '回答正确' : '回答错误',
            style: TextStyle(fontWeight: FontWeight.w700, color: foreground),
          ),
          const SizedBox(height: 6),
          MathText(
            '正确答案：$correctAnswerText',
            style: TextStyle(color: foreground),
          ),
          if (aiScore != null) ...<Widget>[
            const SizedBox(height: 4),
            Text('AI 评分：$aiScore / 10', style: TextStyle(color: foreground)),
          ],
          // 错题本里的题额外显示「还差几次」的进度
          if (question.isFromMistakeBook) ...<Widget>[
            const SizedBox(height: 4),
            Text(
              question.isMistakeDone
                  ? '错题本：已完成'
                  : '错题本：还需答对 ${question.mistakeScore} 次',
              style: TextStyle(color: foreground),
            ),
          ],
        ],
      ),
    );
  }

  /// 题目解析：无论答对答错都展示，用中性配色和判分结果条区分开。
  Widget _buildAnalysis(BuildContext context) {
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
          MathText(
            question.analysis,
            style: const TextStyle(fontSize: 14, height: 1.6),
            selectable: true,
          ),
        ],
      ),
    );
  }

  /// 「AI 解析」按钮 + 解析结果框。
  List<Widget> _buildAiAnalysisEntry(BuildContext context) {
    return <Widget>[
      SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: aiAnalysisLoading ? null : onRequestAiAnalysis,
          icon: aiAnalysisLoading
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.auto_awesome, size: 18),
          label: Text(aiAnalysisLoading ? '正在生成解析…' : 'AI 解析'),
        ),
      ),
      ..._buildAiAnalysis(context),
    ];
  }

  /// AI 解析区域：只有点过「AI 解析」后才出现，紧跟按钮下方。
  List<Widget> _buildAiAnalysis(BuildContext context) {
    if (!aiAnalysisLoading && aiAnalysis == null && aiAnalysisError == null) {
      return const <Widget>[];
    }

    final ColorScheme colorScheme = Theme.of(context).colorScheme;

    return <Widget>[
      const SizedBox(height: 12),
      Container(
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
                  Icons.auto_awesome,
                  size: 16,
                  color: colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Text(
                  'AI 解析',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (aiAnalysisLoading)
              Row(
                children: <Widget>[
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    '正在生成解析…',
                    style: TextStyle(
                      fontSize: 13,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              )
            else if (aiAnalysisError != null) ...<Widget>[
              Text(
                aiAnalysisError!,
                style: TextStyle(fontSize: 13, color: colorScheme.error),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: onRequestAiAnalysis,
                  child: const Text('重试'),
                ),
              ),
            ] else
              MathText(
                aiAnalysis!,
                style: const TextStyle(fontSize: 14, height: 1.6),
                selectable: true,
              ),
          ],
        ),
      ),
    ];
  }

  /// 已选作答图片的缩略图，右上角叉号可单张移除。
  Widget _buildAnswerImages() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        for (int i = 0; i < answerImages.length; i++)
          Stack(
            children: <Widget>[
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.memory(
                  answerImages[i],
                  width: 84,
                  height: 84,
                  fit: BoxFit.cover,
                ),
              ),
              Positioned(
                top: 0,
                right: 0,
                child: GestureDetector(
                  onTap: () => onRemoveImage(i),
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: const BoxDecoration(
                      color: Colors.black54,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.close,
                      size: 15,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ],
          ),
      ],
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
  final bool selected;
  final bool answered;
  final bool isCorrect;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    Color border = colorScheme.outlineVariant;
    Color background = colorScheme.surface;
    Color foreground = colorScheme.onSurface;

    if (answered) {
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
              child: MathText(option.text, style: TextStyle(color: foreground)),
            ),
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
