// AI 出题：调用 DeepSeek 按题库 JSON 格式生成练习题，保存到 App 私有目录。
//
// 存储布局（App Support 目录下）：
//   Question/
//     大学物理学/
//       大学物理学-20251101-170400.json
//       大学物理学-20251101-171230.json
//     ...
// 每个文件都是标准题库 JSON（{"questions":[...]}），与用户自己的题库完全一致：
// 练习、统计回写、错题本收集、题目 id 迁移都按同一套逻辑处理。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'ds_api_service.dart';

/// 一份已生成的 AI 题库文件。
class AiBankInfo {
  const AiBankInfo({
    required this.topic,
    required this.fileName,
    required this.path,
    required this.questionCount,
    required this.modifiedAt,
  });

  /// 主题文件夹名，例如 `大学物理学`。
  final String topic;

  /// 文件名，例如 `大学物理学-20251101-170400.json`。
  final String fileName;

  /// JSON 文件的绝对路径。
  final String path;

  /// 题目数量。
  final int questionCount;

  /// 文件最后修改时间。
  final DateTime modifiedAt;

  /// 展示名：去掉 `.json` 后缀。
  String get displayName {
    final String lower = fileName.toLowerCase();
    return lower.endsWith('.json')
        ? fileName.substring(0, fileName.length - 5)
        : fileName;
  }
}

/// AI 出题的存储与生成入口。
class AiQuestionGenerator {
  AiQuestionGenerator._();

  /// 一次生成的题目数量。
  static const int defaultQuestionCount = 25;

  /// AI 出题的根目录（App Support 目录下的 `Question/`），不存在时创建。
  static Future<Directory> rootDirectory() async {
    final Directory support = await getApplicationSupportDirectory();
    final Directory dir = Directory(
      '${support.path}${Platform.pathSeparator}Question',
    );
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 把用户输入的主题变成安全的文件夹名。
  ///
  /// 去掉文件系统不允许的字符；为空时给一个默认名。
  static String sanitizeTopic(String raw) {
    final String trimmed = raw.trim();
    if (trimmed.isEmpty) return '未命名主题';
    return trimmed.replaceAll(RegExp(r'[\\/:*?"<>|\r\n\t]'), '_');
  }

  /// 确保某个主题的目录存在，返回目录对象。
  static Future<Directory> ensureTopicDir(String rawTopic) async {
    final Directory root = await rootDirectory();
    final Directory dir = Directory(
      '${root.path}${Platform.pathSeparator}${sanitizeTopic(rawTopic)}',
    );
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 列出 `Question/` 下的所有主题目录。
  static Future<List<({String name, String path})>>
  listTopicDirectories() async {
    final Directory root = await rootDirectory();
    final List<({String name, String path})> dirs =
        <({String name, String path})>[];
    try {
      await for (final FileSystemEntity entity in root.list()) {
        if (entity is! Directory) continue;
        dirs.add((
          name: entity.path.split(Platform.pathSeparator).last,
          path: entity.path,
        ));
      }
    } catch (error) {
      debugPrint('读取 AI 出题目录失败：$error');
    }
    dirs.sort(
      (({String name, String path}) a, ({String name, String path}) b) =>
          a.name.compareTo(b.name),
    );
    return dirs;
  }

  /// 列出所有已生成的 AI 题库文件，按主题、文件名排序。
  static Future<List<AiBankInfo>> listBanks() async {
    final List<AiBankInfo> banks = <AiBankInfo>[];
    for (final ({String name, String path}) topic
        in await listTopicDirectories()) {
      final Directory topicDir = Directory(topic.path);
      if (!await topicDir.exists()) continue;
      try {
        await for (final FileSystemEntity entity in topicDir.list()) {
          if (entity is! File) continue;
          if (!entity.path.toLowerCase().endsWith('.json')) continue;

          int count = 0;
          try {
            final dynamic decoded = jsonDecode(await entity.readAsString());
            if (decoded is Map && decoded['questions'] is List) {
              count = (decoded['questions'] as List).length;
            }
          } catch (_) {
            // 文件损坏：仍列出，题数显示 0
          }

          banks.add(
            AiBankInfo(
              topic: topic.name,
              fileName: entity.path.split(Platform.pathSeparator).last,
              path: entity.path,
              questionCount: count,
              modifiedAt: (await entity.stat()).modified,
            ),
          );
        }
      } catch (error) {
        debugPrint('读取 AI 题库失败：${topic.path} $error');
      }
    }
    banks.sort((AiBankInfo a, AiBankInfo b) {
      final int topicCompare = a.topic.compareTo(b.topic);
      if (topicCompare != 0) return topicCompare;
      return b.modifiedAt.compareTo(a.modifiedAt);
    });
    return banks;
  }

  /// 每本（一个 JSON 文件）最多的题目数量。
  static const int perBook = 25;

  /// 界面可选的全部题型标签（按展示顺序）。
  ///
  /// 数据层与标签的对应关系：
  /// - 单选 → `single_choice`
  /// - 多选 → `multiple_choice`
  /// - 判断 → `true_false`
  /// - 填空 / 名词解释 / 解答 / 证明 → `fill_blank`
  ///   （选项为空数组，correctAnswer 存参考答案文本，作答后由 AI 判分）
  static const List<String> allTypeLabels = <String>[
    '单选',
    '多选',
    '判断',
    '填空',
    '名词解释',
    '解答',
    '证明',
  ];

  /// 调 AI 生成 [count] 道题，校验后按「每本最多 [perBook] 题」切分保存。
  ///
  /// [types] 是中文题型标签（见 [allTypeLabels]）；填空、名词解释、
  /// 解答、证明在数据层统一存为 `fill_blank`。
  /// 生成按批次进行：每批最多 [perBook] 道，避免单次输出过长被截断。
  /// 题目 id 全局连续重编为 `Q001`…；`stats` 归零；`image` 置空。
  /// [onProgress] 在每批完成后回调（已完成题数, 目标题数）。
  ///
  /// 失败（网络、Key、AI 返回不是合法 JSON 等）时抛 [DsApiException]；
  /// 若已有部分批次成功，则保留已生成的文件并返回。
  static Future<List<AiBankInfo>> generateAndSave({
    required String topic,
    required String requirements,
    required List<String> types,
    required int count,
    void Function(int finished, int total)? onProgress,
  }) async {
    final int target = count < 1 ? 1 : count;
    final List<AiBankInfo> saved = <AiBankInfo>[];
    int finished = 0;
    int batchIndex = 0;

    while (finished < target && batchIndex < 10) {
      final int remaining = target - finished;
      final int batchCount = remaining > perBook ? perBook : remaining;
      batchIndex++;

      final String raw = await DsApiService.generateQuestions(
        topic: topic,
        requirements: requirements,
        types: types,
        count: batchCount,
      );

      final List<Map<String, dynamic>> questions = parseQuestions(raw);
      if (questions.isEmpty) {
        if (saved.isEmpty) {
          throw DsApiException('AI 返回的题目格式不正确，请重试');
        }
        break; // 后续批次失败：保留已生成的部分
      }

      // AI 可能多给，按本批需求截断
      final List<Map<String, dynamic>> batchQuestions =
          questions.length > batchCount
          ? questions.sublist(0, batchCount)
          : questions;

      // 全局连续编号，保证与题库格式一致
      for (int i = 0; i < batchQuestions.length; i++) {
        batchQuestions[i]['id'] =
            'Q${(finished + i + 1).toString().padLeft(3, '0')}';
      }

      saved.add(
        await _saveBook(
          topic: topic,
          questions: batchQuestions,
          index: batchIndex,
        ),
      );
      finished += batchQuestions.length;
      onProgress?.call(finished, target);
    }
    return saved;
  }

  /// 把一批题目写成一个题库文件：`<主题>-<时间戳>-<批次>.json`。
  static Future<AiBankInfo> _saveBook({
    required String topic,
    required List<Map<String, dynamic>> questions,
    required int index,
  }) async {
    final Directory topicDir = await ensureTopicDir(topic);
    final String safeTopic = sanitizeTopic(topic);
    final String fileName = '$safeTopic-${_timestamp()}-$index.json';
    final File file = File(
      '${topicDir.path}${Platform.pathSeparator}$fileName',
    );

    final String content = const JsonEncoder.withIndent('  ')
        .convert(<String, dynamic>{'questions': questions});
    await file.writeAsString(content, flush: true);

    // 如果主题目录名与用户输入的原始主题不同，以实际目录名为准
    final String actualTopic = topicDir.path.split(Platform.pathSeparator).last;
    return AiBankInfo(
      topic: actualTopic,
      fileName: fileName,
      path: file.path,
      questionCount: questions.length,
      modifiedAt: DateTime.now(),
    );
  }

  /// 从 AI 的原始输出里提取并校验题目列表。
  ///
  /// 容错处理：
  /// - 去掉 ```json 代码围栏；
  /// - 只截取第一个 `{` 到最后一个 `}`；
  /// - 单题字段不全时跳过该题，不因一道题坏掉整批。
  static List<Map<String, dynamic>> parseQuestions(String raw) {
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
      throw DsApiException('AI 返回的内容不是合法 JSON，请重试');
    }
    if (decoded is! Map) {
      throw DsApiException('AI 返回的 JSON 根节点不是对象，请重试');
    }
    final dynamic rawQuestions = decoded['questions'];
    if (rawQuestions is! List) {
      throw DsApiException('AI 返回的 JSON 缺少 questions 数组，请重试');
    }

    final List<Map<String, dynamic>> questions = <Map<String, dynamic>>[];
    for (final dynamic item in rawQuestions) {
      if (item is! Map) continue;
      final Map<String, dynamic>? normalized = _normalizeQuestion(item);
      if (normalized != null) questions.add(normalized);
    }
    return questions;
  }

  /// 校验并规范化一道题；字段不合法时返回 null。
  ///
  /// 支持四种数据层题型：single_choice / multiple_choice / true_false /
  /// fill_blank（填空、解答、证明统一用 fill_blank，没有选项）。
  static Map<String, dynamic>? _normalizeQuestion(Map item) {
    final String type = item['type']?.toString() ?? '';
    final bool isFillBlank = type == 'fill_blank';
    if (!isFillBlank &&
        type != 'single_choice' &&
        type != 'multiple_choice' &&
        type != 'true_false') {
      return null;
    }

    final String question = item['question']?.toString().trim() ?? '';
    if (question.isEmpty) return null;

    // 选项：填空/解答/证明没有选项；其余题型至少 2 个选项
    final List<Map<String, dynamic>> options = <Map<String, dynamic>>[];
    if (!isFillBlank) {
      final dynamic rawOptions = item['options'];
      if (rawOptions is! List) return null;
      for (final dynamic option in rawOptions) {
        if (option is! Map) continue;
        final String key = option['key']?.toString().trim() ?? '';
        final String text = option['text']?.toString().trim() ?? '';
        if (key.isEmpty || text.isEmpty) continue;
        options.add(<String, dynamic>{'key': key, 'text': text});
      }
      if (options.length < 2) return null;
    }

    // 答案：选择题是选项 key；主观题是答案文本（模型偶尔直接给字符串，也接受）
    final dynamic rawAnswer = item['correctAnswer'];
    final List<String> answers = rawAnswer is List
        ? rawAnswer.whereType<String>().map((String s) => s.trim()).toList()
        : (rawAnswer is String && rawAnswer.trim().isNotEmpty
              ? <String>[rawAnswer.trim()]
              : <String>[]);
    if (answers.isEmpty) return null;

    if (!isFillBlank) {
      final Set<String> keys = options
          .map((Map<String, dynamic> o) => o['key'] as String)
          .toSet();
      for (final String answer in answers) {
        if (!keys.contains(answer)) return null; // 答案不在选项里：这题作废
      }
    }

    return <String, dynamic>{
      'id': '', // 稍后统一编号
      'type': type,
      'question': question,
      'image': '',
      'options': options,
      'correctAnswer': answers,
      'analysis': item['analysis']?.toString().trim() ?? '',
      'stats': <String, dynamic>{'attemptCount': 0, 'wrongCount': 0},
    };
  }

  /// 形如 `20251101-170400` 的时间戳，用于生成不重名的文件名。
  static String _timestamp() {
    final DateTime now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${now.year}${two(now.month)}${two(now.day)}'
        '-${two(now.hour)}${two(now.minute)}${two(now.second)}';
  }
}
