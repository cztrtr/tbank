// AI 出题：调用 DeepSeek 按题库 JSON 格式生成练习题，保存到 App 私有目录。
//
// 存储布局（App Support 目录下，支持最多两级目录）：
//   Question/
//     大学物理学/
//       大学物理学-20251101-170400-1.json
//     拍书-高数/
//       期中卷/
//         期中卷-20251102-090000.json     // 拍书出题可指定「一级/二级/文件名」
//     ...
// 每个文件都是标准题库 JSON（{"questions":[...]}），与用户自己的题库完全一致：
// 练习、统计回写、错题本收集、题目 id 迁移都按同一套逻辑处理。
//
// 保存一律「只新增、不覆盖」：同名文件已存在时自动改成 `<名字>-2`、`<名字>-3`…；
// 拍书出题页还可以二次确认后彻底删除（见 [AiQuestionGenerator.deleteBank]）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/question_bank_file.dart';
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
    return ensureBankDir(rawTopic);
  }

  /// 确保保存目录存在：`Question/<一级>[/<二级>]`。
  ///
  /// 拍书出题允许用户指定「一级目录/二级目录」，因此这里支持两层嵌套；
  /// 传空子目录时就是普通的一级主题目录。
  static Future<Directory> ensureBankDir(
    String rawTopic, {
    String? rawSubTopic,
  }) async {
    return _resolveBankDir(rawTopic, rawSubTopic: rawSubTopic, create: true);
  }

  /// 算出（必要时创建）`Question/<一级>[/<二级>]` 目录。
  ///
  /// [create] 为 false 时只计算路径、不落盘，供「预留文件名」使用，
  /// 避免生成失败后在磁盘上留下空目录。
  static Future<Directory> _resolveBankDir(
    String rawTopic, {
    String? rawSubTopic,
    required bool create,
  }) async {
    final Directory root = await rootDirectory();
    final String sub = (rawSubTopic ?? '').trim();
    final String relative = sub.isEmpty
        ? sanitizeTopic(rawTopic)
        : '${sanitizeTopic(rawTopic)}'
              '${Platform.pathSeparator}${sanitizeTopic(sub)}';
    final Directory dir = Directory(
      '${root.path}${Platform.pathSeparator}$relative',
    );
    if (create && !await dir.exists()) {
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
  ///
  /// 支持两级目录：`Question/<主题>/` 下的文件，以及
  /// `Question/<主题>/<子主题>/` 下的文件（拍书出题的自定义保存位置）。
  /// 子目录里的文件用「主题/子主题」作为分组名。
  static Future<List<AiBankInfo>> listBanks() async {
    final List<AiBankInfo> banks = <AiBankInfo>[];
    for (final ({String name, String path}) topic
        in await listTopicDirectories()) {
      final Directory topicDir = Directory(topic.path);
      if (!await topicDir.exists()) continue;
      try {
        await for (final FileSystemEntity entity in topicDir.list()) {
          if (entity is File) {
            final AiBankInfo? info = await _bankInfoFrom(entity, topic.name);
            if (info != null) banks.add(info);
          } else if (entity is Directory) {
            // 二级目录：再扫一层，分组名用「主题/子主题」
            final String subName = entity.path
                .split(Platform.pathSeparator)
                .last;
            await for (final FileSystemEntity sub in entity.list()) {
              if (sub is! File) continue;
              final AiBankInfo? info = await _bankInfoFrom(
                sub,
                '${topic.name}/$subName',
              );
              if (info != null) banks.add(info);
            }
          }
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

  /// 把已生成的题库转成 [QuestionBankFile]，供管理页 / 错题本统一扫描。
  static Future<List<QuestionBankFile>> listBankFiles() async {
    final List<AiBankInfo> banks = await listBanks();
    return banks
        .map(
          (AiBankInfo bank) => QuestionBankFile(
            name: bank.fileName,
            uri: bank.path,
            directoryRef: File(bank.path).parent.path,
            directoryName: bank.topic,
          ),
        )
        .toList();
  }

  /// 读取单个文件的题数与修改时间；不是 `.json` 时返回 null。
  static Future<AiBankInfo?> _bankInfoFrom(File file, String groupName) async {
    if (!file.path.toLowerCase().endsWith('.json')) return null;

    int count = 0;
    try {
      final dynamic decoded = jsonDecode(await file.readAsString());
      if (decoded is Map && decoded['questions'] is List) {
        count = (decoded['questions'] as List).length;
      }
    } catch (_) {
      // 文件损坏：仍列出，题数显示 0
    }

    return AiBankInfo(
      topic: groupName,
      fileName: file.path.split(Platform.pathSeparator).last,
      path: file.path,
      questionCount: count,
      modifiedAt: (await file.stat()).modified,
    );
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

  /// 把一批题目保存到自定义位置，供拍书出题使用。
  ///
  /// 目录为 `Question/<topic>[/<subTopic>]`，文件名为 `<baseName>.json`；
  /// [batchIndex] 从 1 开始，第二批起文件名追加 `-2`、`-3`。
  /// [baseName] 为空时用 `<topic>-<时间戳>`。
  ///
  /// **不会覆盖已有题库**：目标文件名已被占用时自动改用
  /// `<名字>-2.json`、`<名字>-3.json`…（见 [_uniqueBaseName]）。
  /// 想要「整轮生成用一个基名」时，先用 [reserveBaseName] 预留，
  /// 再把结果作为 [baseName] 传进来。
  static Future<AiBankInfo> saveBatchTo({
    required String topic,
    String? subTopic,
    String? baseName,
    required List<Map<String, dynamic>> questions,
    required int batchIndex,
  }) async {
    final Directory dir = await ensureBankDir(topic, rawSubTopic: subTopic);
    final String requested = sanitizeTopic(
      (baseName == null || baseName.trim().isEmpty)
          ? '$topic-${_timestamp()}'
          : baseName.trim(),
    );
    final String stem = batchIndex <= 1 ? requested : '$requested-$batchIndex';
    // 兜底：即使调用方没预留、或历史文件刚好同名，也不会覆盖
    final String base = _uniqueBaseName(dir, stem);
    final File file = File('${dir.path}${Platform.pathSeparator}$base.json');

    final String content = const JsonEncoder.withIndent('  ')
        .convert(<String, dynamic>{'questions': questions});
    await file.writeAsString(content, flush: true);

    // 与 listBanks 保持一致：子目录文件的分组名是「主题/子主题」
    final String safeTopic = sanitizeTopic(topic);
    final String sub = (subTopic ?? '').trim();
    final String groupName = sub.isEmpty
        ? safeTopic
        : '$safeTopic/${sanitizeTopic(sub)}';

    return AiBankInfo(
      topic: groupName,
      fileName: '$base.json',
      path: file.path,
      questionCount: questions.length,
      modifiedAt: DateTime.now(),
    );
  }

  /// 为「一次生成」预留题库基名，保证不会覆盖已有文件。
  ///
  /// 用户填了文件名时以它为基础；留空时用 `<一级目录>-<时间戳>`。
  /// 目录里已经有同名文件时，自动改成 `<名字>-2`、`<名字>-3`…，
  /// 因此同一个位置重复生成只是**并排新增**，旧题库原样保留。
  ///
  /// 只计算名字，不创建目录、不写文件；生成失败不会留下空目录。
  /// 返回的基名交给 [saveBatchTo] 的 `baseName` 使用。
  static Future<String> reserveBaseName({
    required String topic,
    String? subTopic,
    String? baseName,
  }) async {
    final Directory dir = await _resolveBankDir(
      topic,
      rawSubTopic: subTopic,
      create: false,
    );
    final String requested = sanitizeTopic(
      (baseName == null || baseName.trim().isEmpty)
          ? '$topic-${_timestamp()}'
          : baseName.trim(),
    );
    return _uniqueBaseName(dir, requested);
  }

  /// 在 [dir] 里为 [base] 找一个没被占用的题库基名。
  ///
  /// 依次尝试 `base`、`base-2`、`base-3`…；全部被占用（理论上 999 个同名
  /// 文件）时退回带时间戳的名字。宁可名字长一点，也绝不覆盖旧题库。
  static String _uniqueBaseName(Directory dir, String base) {
    bool taken(String stem) =>
        File('${dir.path}${Platform.pathSeparator}$stem.json').existsSync();

    if (!taken(base)) return base;
    for (int index = 2; index <= 999; index++) {
      final String candidate = '$base-$index';
      if (!taken(candidate)) return candidate;
    }
    return '$base-${_timestamp()}';
  }

  /// 彻底删除一份 AI 题库文件（拍书出题 / AI 出题生成的 `.json`）。
  ///
  /// 只删 [bank] 指向的那个文件；删完后如果一级 / 二级目录空了，
  /// 顺带把空目录清掉，`Question/` 根目录始终保留。
  /// 文件本来就不存在时静默返回，不抛异常。
  static Future<void> deleteBank(AiBankInfo bank) async {
    final File file = File(bank.path);
    if (await file.exists()) await file.delete();
    await _removeEmptyParents(file.parent);
  }

  /// 从 [dir] 开始向上删除空目录，最多清理两级（二级、一级目录）。
  ///
  /// 只在目录**完全为空**时删除，用户手动放进去的其它文件不会被牵连；
  /// 遇到非空目录或 `Question/` 根目录立即停止。
  static Future<void> _removeEmptyParents(Directory dir) async {
    final Directory root = await rootDirectory();
    final String rootPrefix = '${root.path}${Platform.pathSeparator}';
    Directory current = dir;
    while (current.path != root.path && current.path.startsWith(rootPrefix)) {
      if (!await current.exists()) return;
      final List<FileSystemEntity> children = await current.list().toList();
      if (children.isNotEmpty) return;
      await current.delete();
      current = current.parent;
    }
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
  static Map<String, dynamic>? _normalizeQuestion(
    Map<dynamic, dynamic> item,
  ) {
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
