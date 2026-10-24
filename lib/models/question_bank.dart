/// 题库文件结构：{ "questions": [...] }
///
/// 一个题库就是一份 JSON，题目全部在 `questions` 数组里。
/// 这里只做数据承载，不包含答题逻辑；答题、统计更新在 PracticePage。
class QuestionBank {
  QuestionBank({required this.questions});

  /// 题目列表，顺序与文件里的顺序一致。
  final List<Question> questions;

  /// 从 JSON 根对象解析题库；questions 不是数组时按空题库处理。
  factory QuestionBank.fromJson(Map<String, dynamic> json) {
    final raw = json['questions'];
    return QuestionBank(
      questions: raw is List
          ? raw
              .whereType<Map>()
              .map((item) => Question.fromJson(item.cast<String, dynamic>()))
              .toList()
          : <Question>[],
    );
  }

  /// 写回文件时只输出 questions，原文件里额外的顶层字段不会保留。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'questions': questions.map((question) => question.toJson()).toList(),
      };
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
  static QuestionType parse(String raw) {
    for (final type in QuestionType.values) {
      if (type.value == raw) return type;
    }
    return QuestionType.fillBlank;
  }
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
    required this.question,
    required this.options,
    required this.correctAnswers,
    required this.stats,
    this.image = '',
  });

  final String id;
  final QuestionType type;
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

  /// 统计对象是可变引用：答题时直接改 attemptCount / wrongCount，
  /// 保存时整份题库序列化会自动带上最新值。
  final QuestionStats stats;

  /// 填空/解释：没有选项，展示答案后由用户自己判断对错。
  bool get isFillBlank => type == QuestionType.fillBlank;

  /// 多选允许选多个，提交时比较集合是否完全相等。
  bool get isMultipleChoice => type == QuestionType.multipleChoice;

  /// 这道题是否配了图片。
  bool get hasImage => image.trim().isNotEmpty;

  factory Question.fromJson(Map<String, dynamic> json) {
    final rawOptions = json['options'];
    final rawAnswer = json['correctAnswer'];
    final rawStats = json['stats'];

    return Question(
      id: json['id']?.toString() ?? '',
      type: QuestionType.parse(json['type']?.toString() ?? ''),
      question: json['question']?.toString() ?? '',
      // 没写、写成 null 或空串，都按“这道题没有图片”处理
      image: json['image']?.toString().trim() ?? '',
      options: rawOptions is List
          ? rawOptions
              .whereType<Map>()
              .map((item) =>
                  QuestionOption.fromJson(item.cast<String, dynamic>()))
              .toList()
          : <QuestionOption>[],
      // correctAnswer 统一按数组读取。仅为兼容旧题库保留字符串写法：
      // 旧的 "B" 会被当成 ["B"]，下次保存时会自动转成数组形态。
      correctAnswers: rawAnswer is List
          ? rawAnswer.whereType<String>().toList()
          : rawAnswer is String
              ? <String>[rawAnswer]
              : <String>[],
      // stats 缺失时补 0/0，老文件也能正常打开
      stats: rawStats is Map
          ? QuestionStats.fromJson(rawStats.cast<String, dynamic>())
          : QuestionStats(),
    );
  }

  /// 序列化回 JSON。
  ///
  /// `correctAnswer` 一律写成数组：单选单元素、多选多元素、填空是文本。
  /// 解析端因此不需要按题型分支，统一当列表处理。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'type': type.value,
        'question': question,
        // 必须始终写回：漏掉这一行的话，答完一题触发 save() 时
        // 整份题库被重新序列化，配图信息就会被静默抹掉。
        'image': image,
        'options': options.map((option) => option.toJson()).toList(),
        // 统一数组形态，例如 ["A"] / ["A","C"] / ["H2O"]
        'correctAnswer': correctAnswers,
        'stats': stats.toJson(),
      };
}

/// 一个选项，例如 { "key": "A", "text": "上海" }。
class QuestionOption {
  const QuestionOption({required this.key, required this.text});

  final String key;
  final String text;

  factory QuestionOption.fromJson(Map<String, dynamic> json) =>
      QuestionOption(
        key: json['key']?.toString() ?? '',
        text: json['text']?.toString() ?? '',
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'key': key,
        'text': text,
      };
}

/// 单题的作答统计。
///
/// 只记录累计次数，不记录每次作答明细；字段直接对应 JSON 里的 stats 对象。
class QuestionStats {
  QuestionStats({this.attemptCount = 0, this.wrongCount = 0});

  int attemptCount; // 一共答了多少次
  int wrongCount; // 其中错了多少次

  factory QuestionStats.fromJson(Map<String, dynamic> json) => QuestionStats(
        attemptCount: (json['attemptCount'] as num?)?.toInt() ?? 0,
        wrongCount: (json['wrongCount'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'attemptCount': attemptCount,
        'wrongCount': wrongCount,
      };
}
