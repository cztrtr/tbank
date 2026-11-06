import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'app_config.dart';
import 'ds_api_exception.dart';
import 'ds_transport.dart';

export 'ds_api_exception.dart';
export 'ds_transport.dart' show DsStreamDelta;

/// DeepSeek 对话 API 的封装（OpenAI 兼容协议），固定使用 `deepseek-flash`。
///
/// 用法：
/// ```dart
/// // 非流式，关闭推理
/// final a = await DsApiService.ask('什么是间皮？', stream: false, thinking: false);
///
/// // 流式，启用推理
/// final b = await DsApiService.ask(
///   '为什么这题选 B？',
///   stream: true,
///   thinking: true,
///   onDelta: (chunk) => setState(() => _answer += chunk),
///   onReasoning: (chunk) => setState(() => _thinking += chunk),
/// );
/// ```
///
/// 失败时抛出 [DsApiException]。
class DsApiService {
  DsApiService._();

  /// 唯一使用的模型。
  static const String model = 'deepseek-flash';

  static const String _baseUrl = 'https://api.deepseek.com';

  /// 普通请求（判分 / 解析 / 问答）的超时。
  static const Duration _defaultTimeout = Duration(seconds: 120);

  /// 出题类请求的超时：一次最多生成 25 道题的完整 JSON，输出很长，
  /// 给足 5 分钟，避免长输出被中途掐断。
  static const Duration _generationTimeout = Duration(seconds: 300);

  /// 发起一次对话，返回完整回答文本。
  ///
  /// - [content]：要询问的内容；
  /// - [stream]：是否流式输出。为 true 时每收到一段就调用 [onDelta]，
  ///   同时把全文累积起来作为返回值；
  /// - [thinking]：是否启用推理（思考模式）。启用后模型会先输出思考过程，
  ///   通过 [onReasoning] 回调给出（非流式时为一次性整段）。
  ///
  /// API Key 取自 `AppConfig.dsApiKey`，未配置时直接抛异常。
  static Future<String> ask(
    String content, {
    required bool stream,
    required bool thinking,
    void Function(String delta)? onDelta,
    void Function(String delta)? onReasoning,
  }) async {
    final String question = content.trim();
    if (question.isEmpty) {
      throw DsApiException('问题内容不能为空');
    }
    return _send(
      question,
      stream: stream,
      thinking: thinking,
      onDelta: onDelta,
      onReasoning: onReasoning,
    );
  }

  /// 真正发请求的地方。
  ///
  /// [content] 可以是纯字符串，也可以是 OpenAI 兼容的内容块数组
  /// （带图片时使用，见 [scoreAnswer]）。
  static Future<String> _send(
    Object content, {
    required bool stream,
    required bool thinking,
    void Function(String delta)? onDelta,
    void Function(String delta)? onReasoning,
    Duration timeout = _defaultTimeout,
  }) async {
    final String apiKey = (AppConfig.dsApiKey ?? '').trim();
    if (apiKey.isEmpty) {
      throw DsApiException('未配置 DeepSeek API Key，请先在设置里填写');
    }

    final Map<String, dynamic> payload = <String, dynamic>{
      'model': model,
      'messages': <Map<String, dynamic>>[
        <String, dynamic>{'role': 'user', 'content': content},
      ],
      'stream': stream,
      'thinking': <String, String>{'type': thinking ? 'enabled' : 'disabled'},
    };

    final Uri uri = Uri.parse('$_baseUrl/chat/completions');
    final Map<String, String> headers = <String, String>{
      'Authorization': 'Bearer $apiKey',
      'Content-Type': 'application/json',
      'Accept': stream ? 'text/event-stream' : 'application/json',
    };

    return stream
        ? DsTransport.chatStream(
            uri,
            headers,
            payload,
            onDelta,
            onReasoning,
            timeout,
          )
        : DsTransport.chatOnce(uri, headers, payload, onReasoning, timeout);
  }

  // ---------------------------------------------------------------- 判分

  /// 让 AI 给主观题（填空 / 解释）打分，返回 0-10 的整数。
  ///
  /// [imageBytes] 是题目配图；[answerImages] 是学生拍照上传的作答图片，
  /// 可以有多张，会一并发给模型。
  ///
  /// 提示词要求模型只输出一个整数；返回里若混了别的字符，
  /// 会提取第一个整数并夹到 0-10。
  static Future<int> scoreAnswer({
    required String question,
    required String standardAnswer,
    required String userAnswer,
    Uint8List? imageBytes,
    List<Uint8List> answerImages = const <Uint8List>[],
  }) async {
    final String prompt =
        '''
你是大学考试阅卷助手。请判断学生作答与标准答案的契合程度，给出 0 到 10 的整数分数。

评分标准：
- 10：完全正确或语义等价
- 7-9：要点正确，表述略有出入
- 4-6：部分正确，只答到一部分要点
- 1-3：基本错误但沾边
- 0：完全错误或未作答

如果题目或作答中的数学表达式以 LaTeX 书写（如 \$x^2\$、\$\\frac{1}{2}\$），
请按数学含义理解后再判分，不要把 LaTeX 标记当作普通符号。

如果附带图片：
- 标注为「题目配图」的图片用于理解题目；
- 标注为「学生作答图片」的图片是学生的手写 / 拍照答案，
  请先识别图片里的文字和图表，再结合标准答案判分。

题目：$question
标准答案：$standardAnswer
学生作答文字：${userAnswer.isEmpty ? '（没有文字答案，见学生作答图片）' : userAnswer}

只输出一个整数（0-10），不要解释、不要标点。
''';

    // 有配图或作答图片时用“文本 + 图片”的内容块数组，否则发纯文本
    final String raw = await _send(
      _withImages(
        prompt,
        questionImage: imageBytes,
        answerImages: answerImages,
      ),
      stream: false,
      thinking: false,
    );
    return _parseScore(raw);
  }

  /// 让 AI 生成一道题的解析。
  ///
  /// [options] 是已格式化的选项文本，一行一个，例如 `A. 上海`；主观题传空串。
  /// [correctAnswer] 形如 `B. 北京`，主观题就是标准答案文本。
  /// [userAnswer] 是学生的主观题作答文字（可选）；[answerImages] 是作答图片。
  /// 题目自带配图时用 [imageBytes] 一起发送。
  static Future<String> explainQuestion({
    required String question,
    required String options,
    required String correctAnswer,
    String? userAnswer,
    Uint8List? imageBytes,
    List<Uint8List> answerImages = const <Uint8List>[],
  }) async {
    final bool hasOptions = options.trim().isNotEmpty;
    final String studentAnswer = (userAnswer ?? '').trim();

    // 选择题讲「为什么对、别的选项为什么错」；主观题讲「怎么做、作答错在哪」
    final String task = hasOptions
        ? '- 说明正确答案为什么正确；\n- 简要说明其它选项为什么不对；'
        : '- 给出清晰的解题思路和完整推导步骤；\n'
              '- 如果附有学生作答，指出思路是否正确、错在哪里、应如何改正；';

    final String prompt =
        '''
你是大学课程答疑老师。请针对下面这道题给出解析。

要求：
$task
- 如果有附图，结合图片内容解释；
- 数学表达式一律用 LaTeX 表示：行内公式用 \$...\$，独立公式用 \$\$...\$\$；
- 每个公式都必须完整包在 \$...\$ 或 \$\$...\$\$ 里，禁止把 \\frac、\\sqrt 等命令裸写在正文中，
  例如必须写 \$\\frac{1}{2}\$，不能写 \\frac{1}{2}；
- 不要使用 \\(...\\) 或 \\[...\\] 作为公式分隔符；
- 公式内不要夹杂中文，需要中文说明时写在公式外面；
- 不要用 Unicode 符号或纯文本凑合（例如写 \$x^2\$ 而不是 x^2）；
- 输出纯文本，不要 Markdown 标记、不要用星号或井号分点；
- 控制在 300 字以内。

题目：$question

${hasOptions ? '选项：\n$options\n' : ''}正确答案：$correctAnswer
${studentAnswer.isEmpty ? '' : '\n学生作答：$studentAnswer'}
''';

    final String text = await _send(
      _withImages(
        prompt,
        questionImage: imageBytes,
        answerImages: answerImages,
      ),
      stream: false,
      thinking: false,
    );
    final String trimmed = text.trim();
    if (trimmed.isEmpty) {
      throw DsApiException('AI 未返回解析内容');
    }
    return trimmed;
  }

  /// 让 AI 根据主题和要求生成一整套练习题，返回模型输出的原始 JSON 文本。
  ///
  /// [count] 是这一批生成的题目数量（调用方按每本上限分批调用）。
  /// [types] 是中文题型标签列表，支持：单选、多选、判断、填空、名词解释、
  /// 解答、证明。其中填空 / 名词解释 / 解答 / 证明在数据层统一映射为
  /// `fill_blank`。
  ///
  /// 提示词约定：
  /// - 一次生成 [count] 道题，按所选题型平均分配；
  /// - 选择题的正确答案在 A~E 上随机均匀分布，不允许集中；
  /// - 数学式使用 LaTeX；
  /// - 只输出 JSON，不要解释和代码围栏。
  ///
  /// 解析、校验与落盘由调用方（AiQuestionGenerator）负责。
  static Future<String> generateQuestions({
    required String topic,
    required String requirements,
    required List<String> types,
    required int count,
  }) async {
    final String typeList = types.join('、');
    final int safeCount = count < 1 ? 1 : count;

    final String prompt =
        '''
你是学科出题老师。请根据下面的主题和要求，生成 $safeCount 道练习题。

主题：$topic
要求：$requirements
题型：$typeList

${_questionFormatRules(safeCount)}
''';

    return _send(
      prompt,
      stream: false,
      thinking: false,
      timeout: _generationTimeout,
    );
  }

  /// 通读一份题库的题目，归纳出它们覆盖的知识点。
  ///
  /// [questionsText] 是调用方整理好的题目摘要（题干 / 选项 / 答案 / 解析）；
  /// 题目太多时由调用方采样截断，避免超出上下文。返回去重后的知识点列表。
  static Future<List<String>> extractKnowledgePoints({
    required String bankName,
    required String questionsText,
  }) async {
    final String prompt =
        '''
你是学科教研老师。下面是一份题库「$bankName」里的题目。

任务：通读这些题目，归纳出它们实际考察的**知识点**，供后续重新出题使用。

要求：
1. 知识点要具体、可考，例如「牛顿第二定律的应用」「洛伦兹力方向的判断」，
   不要用「力学」「电磁学」这种过于宽泛的章节名；
2. 数量依题库内容而定，通常 8~30 个，要能覆盖每一道题背后的考点；
3. 只输出一个 JSON 对象，不要任何解释文字，不要 Markdown 代码围栏：
{"knowledgePoints":["知识点1","知识点2"]}

题库内容：
$questionsText
''';

    final String raw = await _send(prompt, stream: false, thinking: false);
    return parseKnowledgePoints(raw);
  }

  /// 围绕一组知识点重新出题（变式题），返回模型输出的原始 JSON 文本。
  ///
  /// 与 [generateQuestions] 的区别：题目必须围绕给定的知识点、并且
  /// 与原题库保持不同角度（换情景、换数据、换问法），不能机械照抄。
  static Future<String> generateQuestionsFromKnowledge({
    required String topic,
    required List<String> knowledgePoints,
    required List<String> types,
    required int count,
  }) async {
    final String typeList = types.join('、');
    final int safeCount = count < 1 ? 1 : count;
    final String points = knowledgePoints
        .map((String point) => '- $point')
        .join('\n');

    final String prompt =
        '''
你是学科出题老师。下面是一份题库覆盖的知识点，请围绕这些知识点重新出一批**新题**。

题库主题：$topic
知识点（共 ${knowledgePoints.length} 个）：
$points

出题要求：
- 共生成 $safeCount 道题，尽量覆盖上面每一个知识点，重要知识点可以出 1~2 道；
- 必须是与原题库不同角度的新题：换情景、换数据、换问法，不能照抄原题；
- 题型：$typeList。

${_questionFormatRules(safeCount)}
''';

    return _send(
      prompt,
      stream: false,
      thinking: false,
      timeout: _generationTimeout,
    );
  }

  /// 根据用户拍摄的图片生成练习题（拍书出题）。
  ///
  /// 图片里可以是**题目**（模仿出同类型新题），也可以是**知识点讲解**
  /// （围绕图中内容出题）；[requirements] 是用户补充的具体出题要求，
  /// 为空时只要求围绕图片内容出题。
  ///
  /// 图片会以「用户拍摄的图片」标签发给模型，见 [_withImages]。
  static Future<String> generateQuestionsFromImages({
    required List<Uint8List> images,
    required String requirements,
    required List<String> types,
    required int count,
  }) async {
    final List<Uint8List> valid = images
        .where((Uint8List bytes) => bytes.isNotEmpty)
        .toList();
    if (valid.isEmpty) {
      throw DsApiException('请先拍照或选择图片');
    }

    final String typeList = types.join('、');
    final int safeCount = count < 1 ? 1 : count;
    final String requirementText = requirements.trim().isEmpty
        ? '（未填写，围绕图片内容出题即可）'
        : requirements.trim();

    final String prompt =
        '''
你是学科出题老师。下面附上了用户拍摄的图片，可能是教材 / 课件上的**知识点讲解**，
也可能是**题目**。请先仔细识别图片内容，再按要求出一批练习题。

用户的具体出题要求：$requirementText

出题要求：
- 共生成 $safeCount 道题；
- 图片里是题目：优先模仿图片中题目的题型、难度和考点，出同类型的新题
  （换数字、换情景），不要照抄原图；
- 图片里是知识点讲解：围绕图中的知识点出题，尽量覆盖图中所有考点；
- 用户的具体要求与图片内容冲突时，以用户要求为准；
- 题型：$typeList。

${_questionFormatRules(safeCount)}
''';

    return _send(
      _withImages(prompt, answerImages: valid, answerImagesLabel: '用户拍摄的图片'),
      stream: false,
      thinking: false,
      timeout: _generationTimeout,
    );
  }

  /// 从模型输出里解析知识点列表，容忍代码围栏与多余文字。
  ///
  /// 解析失败或一个知识点都没有时抛 [DsApiException]。
  static List<String> parseKnowledgePoints(String raw) {
    String text = raw.trim();
    final RegExpMatch? fenced = RegExp(r'```(?:json)?\s*([\s\S]*?)```')
        .firstMatch(text);
    if (fenced != null) {
      text = fenced.group(1)!.trim();
    }
    final int start = text.indexOf('{');
    final int end = text.lastIndexOf('}');
    if (start >= 0 && end > start) {
      text = text.substring(start, end + 1);
    }

    final dynamic decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      throw DsApiException('AI 返回的知识点不是合法 JSON，请重试');
    }
    if (decoded is! Map) {
      throw DsApiException('AI 返回的知识点 JSON 根节点不是对象，请重试');
    }
    final dynamic rawPoints = decoded['knowledgePoints'];
    if (rawPoints is! List) {
      throw DsApiException('AI 返回的 JSON 缺少 knowledgePoints 数组，请重试');
    }

    final List<String> points = <String>[];
    for (final dynamic item in rawPoints) {
      final String point = item?.toString().trim() ?? '';
      if (point.isNotEmpty && !points.contains(point)) {
        points.add(point);
      }
    }
    if (points.isEmpty) {
      throw DsApiException('AI 没有归纳出任何知识点，请重试');
    }
    return points;
  }

  /// 出题提示词里「输出 JSON 结构」那一段，两种出题方式共用。
  static String _questionFormatRules(int count) {
    final int safeCount = count < 1 ? 1 : count;
    final String lastId = 'Q${safeCount.toString().padLeft(3, '0')}';
    return '''
输出要求：
1. 只输出一个 JSON 对象，不要任何解释文字，不要 Markdown 代码围栏；
2. JSON 结构如下（questions 数组，共 $safeCount 道题，按 Q001~$lastId 顺序编号）：
{"questions":[
  {"id":"Q001","type":"single_choice","question":"题干","image":"",
   "options":[{"key":"A","text":"选项1"},{"key":"B","text":"选项2"},{"key":"C","text":"选项3"},{"key":"D","text":"选项4"}],
   "correctAnswer":["B"],"analysis":"解析",
   "stats":{"attemptCount":0,"wrongCount":0}}
]}
3. 题型与 type 的对应关系：
   - 单选 → single_choice：4~5 个选项（A~E），correctAnswer 写一个选项 key；
   - 多选 → multiple_choice：4~5 个选项，correctAnswer 写 2 个及以上选项 key；
   - 判断 → true_false：固定两个选项 "A.正确" 与 "B.错误"，correctAnswer 写一个 key；
   - 填空 → fill_blank：options 写空数组 []，correctAnswer 写填空答案文本
     （数组，可包含多个可接受答案）；
   - 名词解释 → fill_blank：options 写空数组 []，correctAnswer 写该名词的
     准确定义文本（简洁完整，包含关键特征）；
   - 解答 → fill_blank：options 写空数组 []，correctAnswer 写标准解答要点文本；
   - 证明 → fill_blank：options 写空数组 []，correctAnswer 写证明的关键步骤与结论；
4. 只出「题型」里列出的题型；列出多个题型时尽量平均分配，不要只出其中一种；
5. 选择题的正确答案分布必须随机均匀：A、B、C、D、E 各字母出现次数大致平均，
   禁止大量题目都选同一个字母，也不要把正确答案总放在同一个位置；
6. 题干和解析中的数学表达式用 LaTeX 书写：行内用 \$...\$，独立公式用 \$\$...\$\$；
   每个公式都必须完整包在 \$...\$ 内，禁止裸写 \\frac、\\sqrt 等命令
   （例如写 \$\\frac{1}{2}\$ 而不是 \\frac{1}{2}），公式里不要夹中文；
7. 解析要说明正确答案为什么对、其它选项为什么错；主观题（填空/名词解释/解答/证明）
   在解析里写清得分要点或关键步骤，简洁准确。
''';
  }

  /// 把提示词和可选图片组装成请求的 content。
  ///
  /// - [questionImage]：题干配图；
  /// - [answerImages]：学生作答图片（拍书出题时是用户拍摄的图片），可以多张；
  /// - [answerImagesLabel]：这组图片的文字标签，默认「学生作答图片」。
  ///
  /// 两类图片都带一行文字标签，避免模型把「题目配图」和「学生答案」
  /// 混在一起。没有任何图片时返回纯文本，保持普通请求的形态。
  static Object _withImages(
    String prompt, {
    Uint8List? questionImage,
    List<Uint8List> answerImages = const <Uint8List>[],
    String answerImagesLabel = '学生作答图片',
  }) {
    final List<Uint8List> answers = answerImages
        .where((Uint8List bytes) => bytes.isNotEmpty)
        .toList();
    final bool hasQuestionImage =
        questionImage != null && questionImage.isNotEmpty;

    if (!hasQuestionImage && answers.isEmpty) return prompt;

    final List<Map<String, dynamic>> content = <Map<String, dynamic>>[
      <String, dynamic>{'type': 'text', 'text': prompt},
    ];

    if (hasQuestionImage) {
      content.add(<String, dynamic>{'type': 'text', 'text': '题目配图：'});
      content.add(_imageBlock(questionImage));
    }

    if (answers.isNotEmpty) {
      content.add(<String, dynamic>{
        'type': 'text',
        'text': '$answerImagesLabel（共 ${answers.length} 张）：',
      });
      for (final Uint8List bytes in answers) {
        content.add(_imageBlock(bytes));
      }
    }

    return content;
  }

  /// 把一张图片编码成 OpenAI 兼容的 `image_url` 内容块。
  static Map<String, dynamic> _imageBlock(Uint8List bytes) {
    return <String, dynamic>{
      'type': 'image_url',
      'image_url': <String, String>{
        'url': 'data:${_imageMime(bytes)};base64,${base64Encode(bytes)}',
      },
    };
  }

  /// 按文件头判断图片 MIME；官方是按内容而非扩展名识别格式。
  static String _imageMime(Uint8List bytes) {
    bool startsWith(List<int> magic) {
      if (bytes.length < magic.length) return false;
      for (int i = 0; i < magic.length; i++) {
        if (bytes[i] != magic[i]) return false;
      }
      return true;
    }

    if (startsWith(<int>[0xFF, 0xD8, 0xFF])) return 'image/jpeg';
    if (startsWith(<int>[0x89, 0x50, 0x4E, 0x47])) return 'image/png';
    if (startsWith(<int>[0x47, 0x49, 0x46])) return 'image/gif';
    if (startsWith(<int>[0x52, 0x49, 0x46, 0x46])) return 'image/webp';
    return 'image/jpeg'; // 兜底
  }

  /// 从模型输出里提取 0-10 的整数分数。
  static int _parseScore(String raw) {
    final RegExpMatch? match = RegExp(r'\d{1,2}').firstMatch(raw);
    if (match == null) {
      throw DsApiException('AI 未返回有效分数：${raw.trim()}');
    }
    final int score = int.parse(match.group(0)!);
    return score.clamp(0, 10).toInt();
  }

  /// 从一行 SSE 中取出增量内容（正文与思考过程）。
  ///
  /// 实现在 [DsTransport]，这里保留入口方便旧调用方。
  static DsStreamDelta? sseDelta(String line) => DsTransport.sseDelta(line);
}
