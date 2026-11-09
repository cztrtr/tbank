import 'dart:convert';

/// 题库文件结构：{ "questions": [...] }
///
/// 一个题库就是一份 JSON，题目全部在 `questions` 数组里。
/// 这里只做数据承载，不包含答题逻辑；答题、统计更新在 PracticePage。
class QuestionBank {
  QuestionBank({required this.questions, this.plugin, this.pluginVersion});

  /// 题目列表，顺序与文件里的顺序一致。
  final List<Question> questions;

  /// 处理这份题库的插件 id；null 表示内置 standard。
  ///
  /// 一个题库只能由一个插件处理，题目内部不再单独标插件。
  final String? plugin;

  /// 插件协议版本；用于升级兼容，null 视为 1。
  final int? pluginVersion;

  /// 实际生效的插件 id。
  String get effectivePlugin =>
      (plugin == null || plugin!.isEmpty) ? 'standard' : plugin!;

  /// 从 JSON 根对象解析题库；questions 不是数组时按空题库处理。
  factory QuestionBank.fromJson(Map<String, dynamic> json) =>
      QuestionCodec.bankFromJson(json);

  /// 写回文件时只输出 questions，原文件里额外的顶层字段不会保留。
  Map<String, dynamic> toJson() => QuestionCodec.bankToJson(this);
}

/// 题型：单选、多选、判断、填空（填空和解释共用 fill_blank）。
enum QuestionType {
  singleChoice('single_choice'),
  multipleChoice('multiple_choice'),
  trueFalse('true_false'),
  fillBlank('fill_blank');

  const QuestionType(this.value);

  final String value;

  /// 把 JSON 里的 type 转成枚举；未知类型按填空处理，
  /// 避免单个脏字段让整份题库打不开。
  static QuestionType parse(String raw) => QuestionCodec.parseType(raw);
}

/// 一道题。
///
/// 题型决定作答方式：
/// - single_choice / true_false：选一个选项后提交；
/// - multiple_choice：可选多个，集合完全相等才算对；
/// - fill_blank：选项为空，展示答案后由用户自判。
class Question {
  Question({
    required this.id,
    required this.type,
    String? typeId,
    required this.question,
    required this.options,
    required this.correctAnswers,
    required this.stats,
    this.image = '',
    this.analysis = '',
    this.origin,
    this.mistakeScore,
    this.pluginData,
  }) : typeId = typeId ?? type.value;

  final String id;

  /// 内置 UI 能识别的题型；未知插件题型会降级成 fill_blank。
  final QuestionType type;

  /// 文件里的原始题型标识，可能是第三方插件自定义的 id。
  ///
  /// App 的统计、持久化、插件上下文都以这个字段为准；[type] 只用于
  /// 原生 UI 的兼容分支。
  final String typeId;

  final String question;

  /// 配图文件名，例如 `q001.png`；空字符串表示这道题没有图片。
  ///
  /// 只存文件名、不存路径：图片约定放在题库 JSON 所在目录下，
  /// 由练习页用「源 JSON 目录 + 文件名」拼出绝对路径后再加载。
  /// 一道题最多一张图。
  final String image;

  final List<QuestionOption> options;

  /// 正确答案统一存成字符串列表：
  /// 单选/判断/填空只有一个元素，多选有多个。
  final List<String> correctAnswers;

  /// 题目解析，作答后展示；空字符串表示这道题没有解析。
  final String analysis;

  /// 统计对象是可变引用：答题时直接改 attemptCount / wrongCount，
  /// 保存时整份题库序列化会自动带上最新值。
  final QuestionStats stats;

  /// 错题本专用：来源标记，形如 `<原题库文件引用>#<原题目 id>`。
  ///
  /// 普通题库里的题目为 null；只有被收进错题本的副本才带这个字段，
  /// 用于去重，避免同一道题被反复收集。
  final String? origin;

  /// 错题本专用：还需要答对几次才算「完成」。
  ///
  /// 收集进错题本时初始为 3；每次答对 -1、答错 +1，
  /// 减到 0 或以下即视为已完成（题目仍保留在错题本里）。
  /// 普通题库里的题目为 null。
  int? mistakeScore;

  /// 插件私有字段，App 不解释，只在加载/保存时原样保留。
  ///
  /// 插件运行时可以通过 `tbankUpdatePluginData` 修改当前题的这部分数据。
  Map<String, dynamic>? pluginData;

  /// 这道题是否来自错题本。
  bool get isFromMistakeBook => mistakeScore != null;

  /// 错题是否已经「完成」。
  bool get isMistakeDone => (mistakeScore ?? 0) <= 0;

  /// 填空/解释：没有选项，展示答案后由用户自己判断对错。
  bool get isFillBlank => type == QuestionType.fillBlank;

  /// 多选允许选多个，提交时比较集合是否完全相等。
  bool get isMultipleChoice => type == QuestionType.multipleChoice;

  /// 这道题是否配了图片。
  bool get hasImage => image.trim().isNotEmpty;

  /// 这道题是否有解析。
  bool get hasAnalysis => analysis.trim().isNotEmpty;

  factory Question.fromJson(Map<String, dynamic> json) =>
      QuestionCodec.questionFromJson(json);

  /// 序列化回 JSON。
  ///
  /// `correctAnswer` 一律写成数组：单选单元素、多选多元素、填空是文本。
  /// 解析端因此不需要按题型分支，统一当列表处理。
  Map<String, dynamic> toJson() => QuestionCodec.questionToJson(this);
}

/// 一个选项，例如 { "key": "A", "text": "上海" }。
class QuestionOption {
  const QuestionOption({required this.key, required this.text});

  final String key;
  final String text;

  factory QuestionOption.fromJson(Map<String, dynamic> json) =>
      QuestionCodec.optionFromJson(json);

  Map<String, dynamic> toJson() => QuestionCodec.optionToJson(this);
}

/// 单题的作答统计。
///
/// 只记录累计次数，不记录每次作答明细；字段直接对应 JSON 里的 stats 对象。
class QuestionStats {
  QuestionStats({this.attemptCount = 0, this.wrongCount = 0});

  int attemptCount; // 一共答了多少次
  int wrongCount; // 其中错了多少次

  factory QuestionStats.fromJson(Map<String, dynamic> json) =>
      QuestionCodec.statsFromJson(json);

  Map<String, dynamic> toJson() => QuestionCodec.statsToJson(this);
}

/// 题库 JSON 编解码的唯一入口。
///
/// 页面、存储、AI 出题都走这里；以后给题目加字段，只需要改本类和
/// [Question] 字段，不用再在多个文件里找 fromJson / toJson。
///
/// 容错策略：
/// - 未知题型按 `fill_blank` 处理，避免一条脏数据让整份题库打不开；
/// - 缺 `stats` 补 0/0，缺 `options` / `correctAnswer` 按空处理；
/// - `image` / `analysis` 永远写回，防止答题保存后配图、解析被静默抹掉。
class QuestionCodec {
  QuestionCodec._();

  /// 从 JSON 根对象解析整份题库。
  static QuestionBank bankFromJson(Map<String, dynamic> json) {
    final dynamic raw = json['questions'];
    final String pluginRaw = (json['plugin']?.toString() ?? '').trim();
    final dynamic versionRaw = json['pluginVersion'];

    return QuestionBank(
      plugin: pluginRaw.isEmpty ? null : pluginRaw,
      pluginVersion: versionRaw is num ? versionRaw.toInt() : null,
      questions: raw is List
          ? raw.whereType<Map<String, dynamic>>().map(questionFromJson).toList()
          : <Question>[],
    );
  }

  /// 写回文件：插件标记放最前面，其余字段仍只保留 questions。
  static Map<String, dynamic> bankToJson(QuestionBank bank) {
    final Map<String, dynamic> json = <String, dynamic>{};
    if (bank.plugin != null && bank.plugin!.isNotEmpty) {
      json['plugin'] = bank.plugin;
    }
    if (bank.pluginVersion != null) {
      json['pluginVersion'] = bank.pluginVersion;
    }
    json['questions'] = bank.questions.map(questionToJson).toList();
    return json;
  }

  /// 把 JSON 里的 type 转成枚举；未知类型按填空处理。
  static QuestionType parseType(String raw) {
    for (final QuestionType type in QuestionType.values) {
      if (type.value == raw) return type;
    }
    return QuestionType.fillBlank;
  }

  /// 解析一道题；字段缺失或类型不对时退回默认值。
  static Question questionFromJson(Map<String, dynamic> json) {
    final dynamic rawOptions = json['options'];
    final dynamic rawAnswer = json['correctAnswer'];
    final dynamic rawStats = json['stats'];
    final dynamic rawMistakeScore = json['mistakeScore'];
    final String rawType = json['type']?.toString().trim() ?? '';
    final String typeId = rawType.isEmpty
        ? QuestionType.fillBlank.value
        : rawType;

    return Question(
      id: json['id']?.toString() ?? '',
      type: parseType(typeId),
      typeId: typeId,
      question: json['question']?.toString() ?? '',
      // 没写、写成 null 或空串，都按“这道题没有图片”处理
      image: json['image']?.toString().trim() ?? '',
      options: rawOptions is List
          ? rawOptions
                .whereType<Map<String, dynamic>>()
                .map(optionFromJson)
                .toList()
          : <QuestionOption>[],
      // correctAnswer 只接受数组；非数组一律视为没有答案
      correctAnswers: rawAnswer is List
          ? rawAnswer.whereType<String>().toList()
          : <String>[],
      // 没写或为 null 时按“无解析”处理
      analysis: json['analysis']?.toString().trim() ?? '',
      // stats 缺失时补 0/0，老文件也能正常打开
      stats: rawStats is Map
          ? statsFromJson(Map<String, dynamic>.from(rawStats))
          : QuestionStats(),
      // 这两个字段只出现在错题本文件里，普通题库读出来是 null
      origin: json['origin']?.toString(),
      mistakeScore: rawMistakeScore is num ? rawMistakeScore.toInt() : null,
      pluginData: json['pluginData'] is Map
          ? Map<String, dynamic>.from(json['pluginData'] as Map)
          : null,
    );
  }

  /// 序列化一道题；`image` / `analysis` 必须始终写回。
  static Map<String, dynamic> questionToJson(
    Question question,
  ) => <String, dynamic>{
    'id': question.id,
    'type': question.typeId,
    'question': question.question,
    'image': question.image,
    'options': question.options.map(optionToJson).toList(),
    // 统一数组形态，例如 ["A"] / ["A","C"] / ["H2O"]
    'correctAnswer': question.correctAnswers,
    'analysis': question.analysis,
    'stats': statsToJson(question.stats),
    // 错题本字段：普通题库不写，保持文件干净
    if (question.origin != null) 'origin': question.origin,
    if (question.mistakeScore != null) 'mistakeScore': question.mistakeScore,
    if (question.pluginData != null) 'pluginData': question.pluginData,
  };

  /// 解析一个选项。
  static QuestionOption optionFromJson(Map<String, dynamic> json) =>
      QuestionOption(
        key: json['key']?.toString() ?? '',
        text: json['text']?.toString() ?? '',
      );

  /// 序列化一个选项。
  static Map<String, dynamic> optionToJson(QuestionOption option) =>
      <String, dynamic>{'key': option.key, 'text': option.text};

  /// 解析统计；字段不是数字时补 0。
  static QuestionStats statsFromJson(Map<String, dynamic> json) {
    final dynamic attempt = json['attemptCount'];
    final dynamic wrong = json['wrongCount'];
    return QuestionStats(
      attemptCount: attempt is num ? attempt.toInt() : 0,
      wrongCount: wrong is num ? wrong.toInt() : 0,
    );
  }

  /// 序列化统计。
  static Map<String, dynamic> statsToJson(QuestionStats stats) =>
      <String, dynamic>{
        'attemptCount': stats.attemptCount,
        'wrongCount': stats.wrongCount,
      };

  /// 从题库文件的原始文本解析；根节点不是对象时抛 [FormatException]。
  static QuestionBank decode(String raw) {
    final dynamic decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw const FormatException('题库文件根节点必须是 JSON 对象');
    }
    return bankFromJson(Map<String, dynamic>.from(decoded));
  }

  /// 序列化整份题库；[pretty] 为 true 时缩进 2 空格。
  static String encode(QuestionBank bank, {bool pretty = true}) {
    final Map<String, dynamic> json = bankToJson(bank);
    return pretty
        ? const JsonEncoder.withIndent('  ').convert(json)
        : jsonEncode(json);
  }

  /// 只输出 questions 数组；错题本等外部结构用。
  static String encodeQuestions(
    List<Question> questions, {
    bool pretty = true,
  }) {
    final Map<String, dynamic> json = <String, dynamic>{
      'questions': questions.map(questionToJson).toList(),
    };
    return pretty
        ? const JsonEncoder.withIndent('  ').convert(json)
        : jsonEncode(json);
  }
}
