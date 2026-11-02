// AI 变式出题：读取已有题库的知识点，重新出题，保存到同一个目录。
//
// 与 AiQuestionGenerator 的区别：
// - 知识点不是用户手输的，而是从原题库的题干 / 选项 / 答案 / 解析里归纳出来的；
// - 题目保存回**原题库所在目录**，文件名按希腊字母递增：
//   `高数第一章-alpha.json` → `高数第一章-beta.json` → `高数第一章-gamma.json` …
//   24 个字母用完后接数字：`高数第一章-alpha-2.json`；
// - 生成的是“同一批知识点的变式题”，换情景、换数据、换问法，不照抄原题。
//
// 存储既可能是 SAF（Android），也可能是普通目录（桌面），
// 统一通过 BankIo 读写，不在这里区分平台。
import 'dart:convert';

import '../models/question_bank.dart';
import '../models/question_bank_file.dart';
import 'ai_question_generator.dart';
import 'bank_io.dart';
import 'ds_api_service.dart';

/// 变式出题的当前阶段。
enum VariantStage { reading, extracting, generating, saving }

/// 一次变式出题的进度。
class VariantProgress {
  const VariantProgress({
    required this.stage,
    this.finished = 0,
    this.total = 0,
    this.knowledgePoints = const <String>[],
  });

  final VariantStage stage;

  /// 本阶段已完成的题数（仅 generating 阶段有意义）。
  final int finished;

  /// 本阶段目标题数。
  final int total;

  /// 归纳出的知识点；extracting 阶段返回空列表。
  final List<String> knowledgePoints;
}

/// 变式出题完成后的结果。
class VariantResult {
  const VariantResult({
    required this.fileName,
    required this.count,
    required this.knowledgePoints,
  });

  /// 新文件名，例如 `高数第一章-beta.json`。
  final String fileName;

  /// 实际写入的题目数量。
  final int count;

  /// 本次使用的知识点。
  final List<String> knowledgePoints;
}

/// 「基于已有题库的知识点重新出题」的入口。
class VariantQuestionGenerator {
  VariantQuestionGenerator._();

  /// 一次 API 调用最多生成多少道（与原 AI 出题保持一致）。
  static const int perBook = 25;

  /// 最多调用多少次 API；防止异常情况下无限排队。
  static const int maxBatches = 10;

  /// 一次最多生成多少道题（界面下拉的上限）。
  static const int maxCount = 100;

  /// 归纳知识点时最多采样多少道原题，避免提示词过长。
  static const int maxSampleQuestions = 60;

  static const int _maxQuestionChars = 260;
  static const int _maxOptionChars = 80;
  static const int _maxAnswerChars = 160;
  static const int _maxAnalysisChars = 160;

  /// 题型在界面 / 提示词里的中文标签。
  static String typeLabel(QuestionType type) {
    return switch (type) {
      QuestionType.singleChoice => '单选',
      QuestionType.multipleChoice => '多选',
      QuestionType.trueFalse => '判断',
      QuestionType.fillBlank => '填空',
    };
  }

  /// 原题库里出现过的题型（中文标签），按固定顺序去重。
  ///
  /// 数据层只有四种类型，所以这里只能区分到「单选 / 多选 / 判断 / 填空」；
  /// 原题库里的填空、名词解释、解答、证明都读成 `fill_blank`，统一显示为
  /// 「填空」。变式出题页面允许在此基础上勾选更细的主观题型
  /// （名词解释 / 解答 / 证明），它们仍统一按 `fill_blank` 生成。
  static List<String> typesOf(QuestionBank bank) {
    final Set<String> present = <String>{
      for (final Question question in bank.questions) typeLabel(question.type),
    };
    const List<String> order = <String>['单选', '多选', '判断', '填空'];
    return order.where(present.contains).toList();
  }

  /// 变式题库的命名后缀：24 个希腊字母的英语读法，小写、按字母顺序。
  ///
  /// 一轮用完后从头接序号：`xxx-alpha-2.json`、`xxx-beta-2.json` …
  static const List<String> greekSuffixes = <String>[
    'alpha',
    'beta',
    'gamma',
    'delta',
    'epsilon',
    'zeta',
    'eta',
    'theta',
    'iota',
    'kappa',
    'lambda',
    'mu',
    'nu',
    'xi',
    'omicron',
    'pi',
    'rho',
    'sigma',
    'tau',
    'upsilon',
    'phi',
    'chi',
    'psi',
    'omega',
  ];

  /// 去掉 `.json` 后缀得到题库基名（大小写不敏感）。
  static String baseName(String sourceName) {
    final String trimmed = sourceName.trim();
    final String lower = trimmed.toLowerCase();
    final String base = lower.endsWith('.json')
        ? trimmed.substring(0, trimmed.length - 5)
        : trimmed;
    return base;
  }

  /// 按指定后缀生成文件名，例如 `高数第一章.json` + `beta` → `高数第一章-beta.json`。
  static String fileNameWithSuffix(String sourceName, String suffix) {
    return '${baseName(sourceName)}-$suffix.json';
  }

  /// 从“目录里已有的文件名”里挑出下一个没被占用的希腊字母文件名。
  ///
  /// 顺序固定为 alpha → beta → gamma … → omega；24 个都用完后
  /// 从 alpha 开始接轮次序号（`-alpha-2`、`-beta-2`…）。
  /// 不按现有文件数量推算，避免删除中间文件后重名覆盖。
  static String pickNextFileName({
    required String sourceName,
    required Set<String> existingNames,
  }) {
    final String base = baseName(sourceName);
    final Set<String> used = existingNames
        .map((String name) => name.toLowerCase())
        .toSet();

    for (int cycle = 1; cycle <= 99; cycle++) {
      for (final String suffix in greekSuffixes) {
        final String name = cycle == 1
            ? '$base-$suffix.json'
            : '$base-$suffix-$cycle.json';
        if (!used.contains(name.toLowerCase())) return name;
      }
    }
    // 理论上到不了这里（24 × 99 个名字）；兜底返回 alpha 以免流程中断
    return fileNameWithSuffix(sourceName, 'alpha');
  }

  /// 读取源题库所在目录，算出这次应该用的文件名。
  ///
  /// 目录读取失败时退回 `-alpha.json`（真正写入时会再报错）。
  static Future<String> nextFileName(QuestionBankFile source) async {
    Set<String> existing = <String>{};
    try {
      final List<QuestionBankFile> files = await BankIo.listJsonFiles(
        source.directoryRef,
      );
      existing = files.map((QuestionBankFile file) => file.name).toSet();
    } catch (_) {
      // 目录暂时读不到：按 alpha 起步，交给写入阶段报错
    }
    return pickNextFileName(sourceName: source.name, existingNames: existing);
  }

  /// 读取并解析源题库；格式不对时抛 [DsApiException]。
  static Future<QuestionBank> loadBank(QuestionBankFile file) async {
    final String text = await BankIo.readText(file.uri);
    final dynamic decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      throw DsApiException('「${file.displayName}」不是合法的 JSON 文件');
    }
    if (decoded is! Map) {
      throw DsApiException('「${file.displayName}」的根节点不是对象');
    }
    return QuestionBank.fromJson(decoded.cast<String, dynamic>());
  }

  /// 基于 [sourceBank] 的知识点生成新题，写到原目录的下一个希腊字母文件。
  ///
  /// 流程：归纳知识点（1 次请求）→ 分批生成（每批最多 [perBook] 道）→ 写入。
  /// 失败时抛 [DsApiException]；已有成功批次但后续失败时，
  /// 仍会把已生成的题目写入文件，避免白跑。
  static Future<VariantResult> generate({
    required QuestionBankFile source,
    required QuestionBank sourceBank,
    required int count,
    required List<String> types,
    void Function(VariantProgress progress)? onProgress,
  }) async {
    if (sourceBank.questions.isEmpty) {
      throw DsApiException('「${source.displayName}」里没有题目，无法归纳知识点');
    }
    if (types.isEmpty) {
      throw DsApiException('请至少选择一种题型');
    }

    final int target = count.clamp(1, maxCount);

    // ---- 1. 归纳知识点 ----
    onProgress?.call(const VariantProgress(stage: VariantStage.extracting));
    final List<String> knowledgePoints =
        await DsApiService.extractKnowledgePoints(
          bankName: source.displayName,
          questionsText: _questionsDigest(sourceBank.questions),
        );
    onProgress?.call(
      VariantProgress(
        stage: VariantStage.generating,
        total: target,
        knowledgePoints: knowledgePoints,
      ),
    );

    // ---- 2. 分批生成 ----
    final List<Map<String, dynamic>> questions = <Map<String, dynamic>>[];
    int batchIndex = 0;

    while (questions.length < target && batchIndex < maxBatches) {
      final int remaining = target - questions.length;
      final int batchCount = remaining > perBook ? perBook : remaining;
      batchIndex++;

      final String raw = await DsApiService.generateQuestionsFromKnowledge(
        topic: source.displayName,
        knowledgePoints: knowledgePoints,
        types: types,
        count: batchCount,
      );

      final List<Map<String, dynamic>> parsed =
          AiQuestionGenerator.parseQuestions(raw);
      if (parsed.isEmpty) {
        if (questions.isEmpty) {
          throw DsApiException('AI 返回的题目格式不正确，请重试');
        }
        break; // 后续批次失败：保留已生成的部分
      }

      // AI 可能多给，按本批需求截断
      final List<Map<String, dynamic>> batch = parsed.length > batchCount
          ? parsed.sublist(0, batchCount)
          : parsed;
      questions.addAll(batch);

      onProgress?.call(
        VariantProgress(
          stage: VariantStage.generating,
          finished: questions.length,
          total: target,
          knowledgePoints: knowledgePoints,
        ),
      );
    }

    if (questions.isEmpty) {
      throw DsApiException('AI 没有生成任何可用题目，请重试');
    }

    // 全局连续编号，保证与题库格式一致
    for (int i = 0; i < questions.length; i++) {
      questions[i]['id'] = 'Q${(i + 1).toString().padLeft(3, '0')}';
    }

    // ---- 3. 写回原目录 ----
    onProgress?.call(
      VariantProgress(
        stage: VariantStage.saving,
        finished: questions.length,
        total: target,
        knowledgePoints: knowledgePoints,
      ),
    );

    final String fileName = await nextFileName(source);
    final String content = const JsonEncoder.withIndent('  ')
        .convert(<String, dynamic>{'questions': questions});
    await BankIo.writeSiblingText(source.directoryRef, fileName, content);

    return VariantResult(
      fileName: fileName,
      count: questions.length,
      knowledgePoints: knowledgePoints,
    );
  }

  /// 把题库整理成给 AI 看的连续文本。
  ///
  /// 题目过多时均匀采样 [maxSampleQuestions] 道，并截断过长字段，
  /// 既保留题型分布，又把提示词长度控制在合理范围。
  static String _questionsDigest(List<Question> questions) {
    final List<Question> sampled = _sample(questions, maxSampleQuestions);
    final StringBuffer buffer = StringBuffer();

    if (sampled.length < questions.length) {
      buffer.writeln('（原题库共 ${questions.length} 题，以下均匀采样 ${sampled.length} 题）');
    }

    for (int i = 0; i < sampled.length; i++) {
      final Question question = sampled[i];
      buffer.writeln('【第 ${i + 1} 题】题型：${typeLabel(question.type)}');
      buffer.writeln('题干：${_clip(question.question, _maxQuestionChars)}');
      if (question.options.isNotEmpty) {
        final String options = question.options
            .map(
              (QuestionOption option) =>
                  '${option.key}. ${_clip(option.text, _maxOptionChars)}',
            )
            .join('；');
        buffer.writeln('选项：$options');
      }
      if (question.correctAnswers.isNotEmpty) {
        buffer.writeln(
          '答案：${_clip(question.correctAnswers.join(' / '), _maxAnswerChars)}',
        );
      }
      if (question.analysis.isNotEmpty) {
        buffer.writeln('解析：${_clip(question.analysis, _maxAnalysisChars)}');
      }
      buffer.writeln();
    }

    return buffer.toString();
  }

  /// 均匀采样 [max] 道题，保持原有顺序。
  static List<Question> _sample(List<Question> questions, int max) {
    if (questions.length <= max) return questions;

    final List<Question> result = <Question>[];
    final double step = questions.length / max;
    for (int i = 0; i < max; i++) {
      final int index = (i * step).floor().clamp(0, questions.length - 1);
      result.add(questions[index]);
    }
    return result;
  }

  /// 截断过长文本，保留可读的省略号。
  static String _clip(String text, int max) {
    final String trimmed = text.trim();
    if (trimmed.length <= max) return trimmed;
    return '${trimmed.substring(0, max)}…';
  }
}
