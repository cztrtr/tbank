// 错题本：把各题库里答错过的题收集到 App 私有目录，单独练。
//
// 存储布局（App Support 目录下）：
//   mistakes/
//     Alpha.json   // 一本最多 25 题
//     Beta.json
//     C001.png     // 错题自带配图，复制过来并按错题编号重命名
//
// 错题本里的每道题比普通题库多两个字段：
//   origin       来源，用于去重。收录时直接记「稳定题目 id」：
//                首次扫描到题库时，App 会把每题的 id 替换成 `q_` 前缀的
//                随机长字符串并写回原文件；origin 只记这个 id，
//                与题库文件的位置无关 —— 文件挪位置、重新加载都不会
//                导致重复收集或丢失记录。
//                旧版本记录的 origin 是 `<文件引用>#<原题 id>`，
//                收集时自动迁移成稳定 id。
//   mistakeScore 还需答对几次才算完成：收集时 3，答对 -1、答错 +1
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/question_bank_file.dart';
import 'app_config.dart';
import 'bank_io.dart';

/// 错题本列表里的一本。
class MistakeBookInfo {
  const MistakeBookInfo({
    required this.name,
    required this.path,
    required this.total,
    required this.completed,
  });

  /// 本子名，例如 `Alpha`。
  final String name;

  /// JSON 文件的绝对路径。
  final String path;

  /// 题目总数。
  final int total;

  /// 已完成的题目数（mistakeScore 减到 0 的那些）。
  final int completed;

  /// 整本是否都已完成。
  bool get isFinished => total > 0 && completed == total;

  /// 转成练习页需要的题库文件描述。
  ///
  /// `name` 只用于 Documents 目录下的工作副本，加前缀避免和用户自己的
  /// 同名题库（例如他恰好也有个 `Alpha.json`）撞车；源文件始终是 `path`。
  QuestionBankFile toBankFile(String directoryPath) => QuestionBankFile(
    name: '错题本-$name.json',
    uri: path,
    directoryRef: directoryPath,
    directoryName: '错题本',
  );
}

/// 错题本的读取、收集与统计。
class MistakeBooks {
  MistakeBooks._();

  /// 一本最多放几道题。
  static const int perBook = 25;

  /// 刚收进错题本时「还需要答对几次」，答对 3 次即视为完成。
  static const int initialScore = 3;

  /// 记录「已删除来源」的清单文件名（不含 `.json`）。
  static const String _deletedBaseName = 'deleted_origins';

  /// 稳定题目 id 的前缀：带这个前缀的 id 是 App 生成的随机 id。
  ///
  /// 用前缀而不是长度/字符集来判断，是因为用户手写的 id 什么形态都可能有，
  /// 前缀是唯一无歧义的标志；同一道题只会生成一次，之后原样保留。
  static const String _stableIdPrefix = 'q_';

  /// 稳定 id 的随机部分长度：26 位 [a-z0-9]，62^26 ≈ 5e46，
  /// 任何两道题撞 id 的概率都可以忽略。
  static const int _stableIdLength = 26;

  /// 判定「已是稳定 id」所需的最小总长度，给手写 id 留出误判余量。
  static const int _stableIdMinLength = 16;

  /// 随机 id 的字符表：去掉大写字母，避免与用户手写的 `Q001` 这类
  /// 大写开头的 id 视觉混淆；去重只看字符串相等，可读性不重要。
  static const String _stableIdAlphabet =
      'abcdefghijklmnopqrstuvwxyz0123456789';

  /// 加密安全的随机数：id 只在生成时算一次，开销可以忽略。
  static final Random _idRandom = Random.secure();

  /// 判断一个 id 是否已经是 App 生成的稳定随机 id。
  static bool _isStableId(String id) =>
      id.startsWith(_stableIdPrefix) && id.length >= _stableIdMinLength;

  /// 生成一个稳定题目 id：`q_` + 26 位随机小写字母数字。
  static String _generateStableId() {
    final StringBuffer buffer = StringBuffer(_stableIdPrefix);
    for (int i = 0; i < _stableIdLength; i++) {
      buffer.write(_stableIdAlphabet[_idRandom.nextInt(_stableIdAlphabet.length)]);
    }
    return buffer.toString();
  }

  /// 本子命名顺序：24 个希腊字母（Alpha…Omega），一轮用完后加序号
  /// （Alpha 2、Beta 2……）。不再使用汉字命名。
  static const List<String> _names = <String>[
    'Alpha',
    'Beta',
    'Gamma',
    'Delta',
    'Epsilon',
    'Zeta',
    'Eta',
    'Theta',
    'Iota',
    'Kappa',
    'Lambda',
    'Mu',
    'Nu',
    'Xi',
    'Omicron',
    'Pi',
    'Rho',
    'Sigma',
    'Tau',
    'Upsilon',
    'Phi',
    'Chi',
    'Psi',
    'Omega',
  ];

  /// 按顺序找出第一个还没被占用的本名。
  ///
  /// 不能用「现有本子数量」推名字：删除中间某本后再新建，
  /// 按数量推算会与已有本子重名，写回时把那一本的数据覆盖掉。
  static String _nextName(Set<String> used) {
    for (int cycle = 1; ; cycle++) {
      for (final String base in _names) {
        final String name = cycle == 1 ? base : '$base $cycle';
        if (!used.contains(name)) return name;
      }
    }
  }

  /// 本子的排序权重，保证 Alpha……Omega 按期望顺序排列。
  ///
  /// 兼容带序号的名字（`Alpha 2`）；无法识别的旧名字
  /// （例如早期版本的汉字本）统一排在最后。
  static int _orderOf(String name) {
    // 先尝试拆出末尾的轮次序号
    final int space = name.lastIndexOf(' ');
    if (space > 0) {
      final int? cycle = int.tryParse(name.substring(space + 1));
      if (cycle != null) {
        final int index = _names.indexOf(name.substring(0, space));
        if (index >= 0) return (cycle - 1) * _names.length + index;
      }
    }

    final int index = _names.indexOf(name);
    return index >= 0 ? index : 1 << 20; // 无法识别的名字排在最后
  }

  /// 错题本所在目录，不存在时自动创建。
  static Future<Directory> directory() async {
    final Directory support = await getApplicationSupportDirectory();
    final Directory dir = Directory(
      '${support.path}${Platform.pathSeparator}mistakes',
    );
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 列出所有错题本，按本名顺序返回。
  static Future<List<MistakeBookInfo>> list() async {
    final Directory dir = await directory();
    final List<File> files = _jsonFiles(dir);
    final List<MistakeBookInfo> books = <MistakeBookInfo>[];

    for (final File file in files) {
      final _BookData? book = await _readBook(file);
      if (book == null) continue;

      int completed = 0;
      for (final Map<String, dynamic> question in book.questions) {
        final raw = question['mistakeScore'];
        if (raw is num && raw.toInt() <= 0) completed++;
      }

      books.add(
        MistakeBookInfo(
          name: book.name,
          path: file.path,
          total: book.questions.length,
          completed: completed,
        ),
      );
    }
    return books;
  }

  /// 扫描所有题库，把答错过的题收进错题本，返回本次新增的题目数。
  ///
  /// 收录前先把各题库里的题目 id 迁移成稳定随机 id（见 [_migrateQuestionIds]），
  /// 之后按稳定 id 去重：文件挪位置、换设备都不会导致重复收集。
  /// 配图会一起复制过来，并按错题编号重命名。
  static Future<int> collectFromBanks() async {
    final Directory dir = await directory();

    // 1. 读出现有本子：已收集的来源、最大错题编号
    final List<_BookData> books = <_BookData>[];
    final Set<String> knownOrigins = <String>{};
    final Set<String> deletedOrigins = await _loadDeletedOrigins(dir);
    int maxNumber = 0;

    for (final File file in _jsonFiles(dir)) {
      final _BookData? book = await _readBook(file);
      if (book == null) continue;
      books.add(book);

      for (final Map<String, dynamic> question in book.questions) {
        final String origin = question['origin']?.toString() ?? '';
        if (origin.isNotEmpty) knownOrigins.add(origin);

        final RegExpMatch? match = RegExp(r'^C(\d+)$')
            .firstMatch(question['id']?.toString() ?? '');
        if (match != null) {
          final int number = int.parse(match.group(1)!);
          if (number > maxNumber) maxNumber = number;
        }
      }
    }

    // 2. 遍历题库目录：
    //    2a. 把每份题库里的题目 id 迁移成稳定随机 id 并回写原文件；
    //    2b. 挑出答错过的题作为收录候选（此时先收集，后面统一判断收录）。
    final List<_Candidate> candidates = <_Candidate>[];
    // 旧 origin → 新 origin 的映射，用于迁移老错题本和删除清单里的记录
    final Map<String, String> originMigrations = <String, String>{};

    for (final String dirRef in AppConfig.questionBankDirsNotifier.value) {
      List<QuestionBankFile> bankFiles;
      try {
        bankFiles = await BankIo.listJsonFiles(
          dirRef,
          directoryName: BankIo.displayNameOf(dirRef),
        );
      } catch (error) {
        debugPrint('扫描题库目录失败：$dirRef $error');
        continue;
      }

      for (final QuestionBankFile bankFile in bankFiles) {
        final dynamic decoded = await _readBankJson(bankFile);
        if (decoded is! Map) continue;

        final dynamic rawQuestions = decoded['questions'];
        if (rawQuestions is! List) continue;

        // 迁移这份题库的题目 id；失败（回写不了）时按未迁移处理
        final bool migrated = await _migrateQuestionIds(
          bankFile,
          decoded,
          originMigrations,
        );

        for (final dynamic item in rawQuestions) {
          if (item is! Map) continue;
          final Map<String, dynamic> question = Map<String, dynamic>.from(item);

          // 只收答错过的题
          final dynamic stats = question['stats'];
          final int wrongCount = (stats is Map && stats['wrongCount'] is num)
              ? (stats['wrongCount'] as num).toInt()
              : 0;
          if (wrongCount <= 0) continue;

          final String id = question['id']?.toString() ?? '';
          // 迁移成功的题库：id 已是稳定随机 id，origin 直接记它，
          // 与文件位置彻底解耦 —— 挪目录、换设备都不影响去重；
          // 迁移失败的题库：沿用旧格式 `<文件引用>#<id>`，行为不回退。
          final String legacyOrigin = '${bankFile.uri}#$id';
          candidates.add(
            _Candidate(
              question: question,
              bankFile: bankFile,
              origin: migrated ? id : legacyOrigin,
              legacyOrigin: legacyOrigin,
            ),
          );
        }
      }
    }

    // 3. 把老错题本里的旧格式 origin 迁移成稳定 id。
    //
    //    不迁移的话，题目 id 已被替换成随机 id，旧记录 `文件引用#旧id`
    //    对不上新数据，同一道题会被当成新错题重复收集。
    final bool booksChanged = await _applyOriginMigrations(
      dir,
      books,
      deletedOrigins,
      originMigrations,
    );

    // 4. 收录候选题：同一条 origin 只收一次，删过的题不再自动收回。
    //
    //    新旧双形态判断：稳定 id 和旧格式键任一命中都视为已收录，
    //    兼容迁移失败、错题本文件损坏等没能完成迁移的情况。
    final List<Map<String, dynamic>> pending = <Map<String, dynamic>>[];

    for (final _Candidate candidate in candidates) {
      if (deletedOrigins.contains(candidate.origin) ||
          deletedOrigins.contains(candidate.legacyOrigin)) {
        continue;
      }
      if (knownOrigins.contains(candidate.origin) ||
          knownOrigins.contains(candidate.legacyOrigin)) {
        continue;
      }
      knownOrigins.add(candidate.origin);

      maxNumber++;
      final String newId = 'C${maxNumber.toString().padLeft(3, '0')}';
      final Map<String, dynamic> question = candidate.question;

      question['id'] = newId;
      question['origin'] = candidate.origin;
      question['mistakeScore'] = initialScore;
      question['image'] = await _copyImage(
        dir,
        candidate.bankFile,
        question['image'],
        newId,
      );

      pending.add(question);
    }

    if (pending.isEmpty && !booksChanged) return 0;

    // 5. 先填已有本子的空位，剩下的按每本 25 题新建
    final List<Map<String, dynamic>> remaining = List<Map<String, dynamic>>.of(
      pending,
    );

    for (final _BookData book in books) {
      while (book.questions.length < perBook && remaining.isNotEmpty) {
        book.questions.add(remaining.removeAt(0));
      }
      if (remaining.isEmpty) break;
    }

    // 从已占用的名字里找下一个空位：删过本子也不会撞名
    final Set<String> usedNames = books
        .map((_BookData book) => book.name)
        .toSet();
    while (remaining.isNotEmpty) {
      final List<Map<String, dynamic>> slice = <Map<String, dynamic>>[];
      while (slice.length < perBook && remaining.isNotEmpty) {
        slice.add(remaining.removeAt(0));
      }
      final String name = _nextName(usedNames);
      usedNames.add(name);
      books.add(_BookData(name: name, questions: slice));
    }

    // 6. 写回所有本子：有新错题、或 origin 完成了迁移，都需要落盘
    for (final _BookData book in books) {
      await _writeBook(dir, book.name, book.questions);
    }
    return pending.length;
  }

  /// 把一份题库 JSON 里所有旧式 id 替换成稳定随机 id，并回写原文件。
  ///
  /// - 文件里所有 id 都已是稳定 id 时直接返回 true（幂等，不写文件）；
  /// - 有替换时整份回写，`questions` 之外的顶层字段原样保留；
  /// - 回写失败时把内存里的 id 全部恢复成旧值并返回 false，
  ///   调用方按「未迁移」处理：origin 沿用旧格式，保证不会重复收集。
  ///
  /// [decoded] 是整份题库的 JSON 对象，键类型放宽为 dynamic——
  /// 从 jsonDecode 得到的 Map 就是这个形态，这里只读不删。
  ///
  /// [migrations] 输出旧 origin → 新 origin 的映射：
  /// 键 `<文件引用>#<旧 id>`，值 `<新稳定 id>`，用于迁移老错题本记录。
  static Future<bool> _migrateQuestionIds(
    QuestionBankFile bankFile,
    Map<dynamic, dynamic> decoded,
    Map<String, String> migrations,
  ) async {
    final dynamic rawQuestions = decoded['questions'];
    if (rawQuestions is! List) return true;

    // 需要替换的题：保留原 item 引用，回写失败时能精确恢复旧 id
    final List<(Map<dynamic, dynamic>, String, String)> replacements =
        <(Map<dynamic, dynamic>, String, String)>[];

    for (final dynamic item in rawQuestions) {
      if (item is! Map) continue;
      final String oldId = item['id']?.toString() ?? '';
      if (_isStableId(oldId)) continue;

      final String newId = _generateStableId();
      item['id'] = newId;
      replacements.add((item, oldId, newId));
    }

    if (replacements.isEmpty) return true;

    try {
      final String content = const JsonEncoder.withIndent(
        '  ',
      ).convert(decoded);
      await BankIo.writeText(bankFile.uri, content);
    } catch (error) {
      debugPrint('迁移题目 id 失败（${bankFile.name}）：$error');
      // 没写进文件就不能用新 id：恢复内存，让它走旧格式 origin
      for (final (Map<dynamic, dynamic> item, String oldId, String _) in replacements) {
        item['id'] = oldId;
      }
      return false;
    }

    for (final (Map<dynamic, dynamic> _, String oldId, String newId)
        in replacements) {
      migrations['${bankFile.uri}#$oldId'] = newId;
    }
    return true;
  }

  /// 把 [migrations]（旧 origin → 新 origin）应用到所有错题本与删除清单。
  ///
  /// 只改写能对上的记录：对不上的说明对应的原题库已不存在，
  /// 保留旧键无害（那道题也不会再被扫描到）。
  /// 删除清单有变化时立即写回；错题本只改内存，由调用方决定何时落盘。
  ///
  /// 返回错题本是否有改动（需要写回）。
  static Future<bool> _applyOriginMigrations(
    Directory dir,
    List<_BookData> books,
    Set<String> deletedOrigins,
    Map<String, String> migrations,
  ) async {
    if (migrations.isEmpty) return false;

    bool booksChanged = false;
    for (final _BookData book in books) {
      for (final Map<String, dynamic> question in book.questions) {
        final String origin = question['origin']?.toString() ?? '';
        final String? migrated = migrations[origin];
        if (migrated == null || migrated == origin) continue;
        question['origin'] = migrated;
        booksChanged = true;
      }
    }

    // 删除清单同样迁移：删过的题不能因为换了 id 就「复活」
    final Set<String> migratedDeleted = <String>{
      for (final String origin in deletedOrigins)
        migrations[origin] ?? origin,
    };
    if (migratedDeleted.length != deletedOrigins.length ||
        !migratedDeleted.containsAll(deletedOrigins)) {
      deletedOrigins
        ..clear()
        ..addAll(migratedDeleted);
      await _saveDeletedOrigins(dir, deletedOrigins);
    }
    return booksChanged;
  }

  /// 对指定目录下的所有题库做一次 id 迁移（添加题库目录时调用）。
  ///
  /// 与 [collectFromBanks] 里的迁移共用同一套逻辑：
  /// 只替换非稳定 id，并把「旧 origin → 新 origin」的映射同步到
  /// 已有错题本和删除清单，保证之后收集错题时去重键一致。
  ///
  /// 幂等：已是稳定 id 的题库不会重写文件。
  /// 失败（目录读不到、文件写不回）只记日志，不影响添加目录本身。
  static Future<void> migrateBankIdsInDirectory(String directoryRef) async {
    try {
      final Map<String, String> migrations = <String, String>{};

      List<QuestionBankFile> bankFiles;
      try {
        bankFiles = await BankIo.listJsonFiles(
          directoryRef,
          directoryName: BankIo.displayNameOf(directoryRef),
        );
      } catch (error) {
        debugPrint('添加目录后扫描题库失败：$directoryRef $error');
        return;
      }

      for (final QuestionBankFile bankFile in bankFiles) {
        final dynamic decoded = await _readBankJson(bankFile);
        if (decoded is! Map) continue;
        await _migrateQuestionIds(bankFile, decoded, migrations);
      }
      if (migrations.isEmpty) return;

      // 迁移映射同样要落到错题本与删除清单，避免之后重复收集
      final Directory dir = await directory();
      final List<_BookData> books = <_BookData>[];
      for (final File file in _jsonFiles(dir)) {
        final _BookData? book = await _readBook(file);
        if (book != null) books.add(book);
      }
      final Set<String> deletedOrigins = await _loadDeletedOrigins(dir);
      final bool booksChanged = await _applyOriginMigrations(
        dir,
        books,
        deletedOrigins,
        migrations,
      );
      if (booksChanged) {
        for (final _BookData book in books) {
          await _writeBook(dir, book.name, book.questions);
        }
      }
    } catch (error) {
      debugPrint('添加目录后迁移题目 id 失败：$directoryRef $error');
    }
  }

  /// 启动时自动迁移所有已添加目录下的题库 id（幂等）。
  ///
  /// 只处理 `config.json` 里已添加的目录；已是稳定 id 的文件不重写，
  /// 因此第二次启动只会读一遍文件、几乎不产生写入。
  /// 单个目录失败不影响其它目录（[migrateBankIdsInDirectory] 内部吞异常）。
  static Future<void> migrateAllBankIds() async {
    final List<String> dirs = List<String>.of(
      AppConfig.questionBankDirsNotifier.value,
    );
    for (final String dirRef in dirs) {
      await migrateBankIdsInDirectory(dirRef);
    }
  }

  /// 重置错题本：删除所有已有错题本（连同配图）并清空删除史。
  ///
  /// 由设置页「重置错题本」按钮手动触发；只影响 App 私有目录，
  /// 原题库的题目和统计不受影响，之后答错的题会重新被收集。
  ///
  /// 单个文件删除失败不会中断整体流程，只记日志；
  /// 全部成功后返回 true（列表刷新由调用方负责）。
  static Future<bool> resetAll() async {
    final Directory dir = await directory();
    bool ok = true;

    // 1. 删除所有错题本 JSON（_jsonFiles 已排除 deleted_origins.json）
    for (final File file in _jsonFiles(dir)) {
      try {
        await file.delete();
      } catch (error) {
        ok = false;
        debugPrint('删除错题本失败：${file.path} $error');
      }
    }

    // 2. 删除配图：先收集再删，避免遍历目录时边删边读
    const Set<String> imageExtensions = <String>{
      '.png',
      '.jpg',
      '.jpeg',
      '.webp',
      '.gif',
    };
    final List<File> images = <File>[];
    await for (final FileSystemEntity entity in dir.list()) {
      if (entity is! File) continue;
      final String lower = entity.path.toLowerCase();
      if (!imageExtensions.any(lower.endsWith)) continue;
      images.add(entity);
    }
    for (final File image in images) {
      try {
        await image.delete();
      } catch (error) {
        ok = false;
        debugPrint('删除错题配图失败：${image.path} $error');
      }
    }

    // 3. 清空「已删除来源」清单：之前删过的题之后也能重新被收集
    final File deletedFile = File(
      '${dir.path}${Platform.pathSeparator}$_deletedBaseName.json',
    );
    try {
      if (await deletedFile.exists()) await deletedFile.delete();
    } catch (error) {
      ok = false;
      debugPrint('清空错题本删除史失败：$error');
    }

    return ok;
  }

  /// 删除一本错题本：连同副本里的配图一起删掉。
  ///
  /// 被删题目的 `origin` 会记进 `deleted_origins.json`，
  /// 之后进入错题本时不会被自动收集回来；
  /// 只影响 App 私有目录，原题库的题目和统计不变。
  static Future<void> deleteBook(MistakeBookInfo book) async {
    final File jsonFile = File(book.path);
    final Directory dir = jsonFile.parent;

    // 先读出题目：JSON 删掉后就拿不到配图文件名和 origin 了
    final _BookData? data = await _readBook(jsonFile);
    final Set<String> origins = <String>{};

    if (data != null) {
      for (final Map<String, dynamic> question in data.questions) {
        final String origin = question['origin']?.toString() ?? '';
        if (origin.isNotEmpty) origins.add(origin);

        final String image = question['image']?.toString().trim() ?? '';
        if (image.isEmpty) continue;

        // 只取文件名，防止 JSON 里写路径把删除操作带到目录外
        final String fileName = image.split(RegExp(r'[\\/]')).last;
        final File target = File(
          '${dir.path}${Platform.pathSeparator}$fileName',
        );
        try {
          if (await target.exists()) await target.delete();
        } catch (error) {
          debugPrint('删除错题配图失败：$fileName $error');
        }
      }
    }

    if (await jsonFile.exists()) await jsonFile.delete();

    if (origins.isNotEmpty) {
      final Set<String> deleted = await _loadDeletedOrigins(dir);
      deleted.addAll(origins);
      await _saveDeletedOrigins(dir, deleted);
    }
  }

  // ---------------------------------------------------------------- 内部

  /// 目录下的 `.json` 文件，按本名顺序排序。
  ///
  /// 跳过用来记录「已删除来源」的清单文件，它不是错题本。
  static List<File> _jsonFiles(Directory dir) {
    final List<File> files = dir
        .listSync()
        .whereType<File>()
        .where(
          (File file) =>
              file.path.toLowerCase().endsWith('.json') &&
              _baseName(file).toLowerCase() != _deletedBaseName,
        )
        .toList();
    files.sort(
      (File a, File b) =>
          _orderOf(_baseName(a)).compareTo(_orderOf(_baseName(b))),
    );
    return files;
  }

  /// 取文件名（去掉 `.json`）。
  static String _baseName(File file) {
    final String name = file.uri.pathSegments.last;
    return name.toLowerCase().endsWith('.json')
        ? name.substring(0, name.length - 5)
        : name;
  }

  /// 读取「已删除来源」清单；文件不存在或损坏时返回空集合。
  static Future<Set<String>> _loadDeletedOrigins(Directory dir) async {
    final File file = File(
      '${dir.path}${Platform.pathSeparator}$_deletedBaseName.json',
    );
    try {
      if (!await file.exists()) return <String>{};
      final dynamic decoded = jsonDecode(await file.readAsString());
      if (decoded is! List) return <String>{};
      return decoded.whereType<String>().toSet();
    } catch (error) {
      debugPrint('读取已删除错题记录失败：$error');
      return <String>{};
    }
  }

  /// 写入「已删除来源」清单，避免删掉的题下次自动收集时复活。
  static Future<void> _saveDeletedOrigins(
    Directory dir,
    Set<String> origins,
  ) async {
    final File file = File(
      '${dir.path}${Platform.pathSeparator}$_deletedBaseName.json',
    );
    final String content = const JsonEncoder.withIndent('  ')
        .convert(<String>[...origins]);
    await file.writeAsString(content, flush: true);
  }

  static Future<_BookData?> _readBook(File file) async {
    try {
      final String text = BankIo.stripBom(await file.readAsString());
      final dynamic decoded = jsonDecode(text);
      if (decoded is! Map) return null;

      final dynamic raw = decoded['questions'];
      final List<Map<String, dynamic>> questions = raw is List
          ? raw
                .whereType<Map>()
                .map((Map item) => Map<String, dynamic>.from(item))
                .toList()
          : <Map<String, dynamic>>[];

      return _BookData(name: _baseName(file), questions: questions);
    } catch (error) {
      debugPrint('读取错题本失败：${file.path} $error');
      return null;
    }
  }

  static Future<dynamic> _readBankJson(QuestionBankFile bankFile) async {
    try {
      final String text = BankIo.stripBom(await BankIo.readText(bankFile.uri));
      return jsonDecode(text);
    } catch (error) {
      debugPrint('读取题库失败：${bankFile.name} $error');
      return null;
    }
  }

  /// 把配图复制到错题本目录，命名为 `<错题编号>.<扩展名>`。
  static Future<String> _copyImage(
    Directory dir,
    QuestionBankFile bankFile,
    dynamic rawImage,
    String newId,
  ) async {
    final String image = rawImage?.toString().trim() ?? '';
    if (image.isEmpty) return '';

    try {
      final Uint8List? bytes = await BankIo.readSiblingBytes(
        bankFile.directoryRef,
        image,
      );
      if (bytes == null || bytes.isEmpty) return '';

      final int dot = image.lastIndexOf('.');
      final String extension = dot >= 0 ? image.substring(dot) : '.png';
      final String fileName = '$newId$extension';

      final File target = File('${dir.path}${Platform.pathSeparator}$fileName');
      await target.writeAsBytes(bytes, flush: true);
      return fileName;
    } catch (error) {
      debugPrint('复制错题配图失败：$image $error');
      return '';
    }
  }

  static Future<void> _writeBook(
    Directory dir,
    String name,
    List<Map<String, dynamic>> questions,
  ) async {
    final File file = File('${dir.path}${Platform.pathSeparator}$name.json');
    // 只写 questions：本子名由文件名承载，格式与普通题库保持一致
    final String content = const JsonEncoder.withIndent('  ')
        .convert(<String, dynamic>{'questions': questions});
    await file.writeAsString(content, flush: true);
  }
}

/// 内存中的一本错题本。
class _BookData {
  _BookData({required this.name, required this.questions});

  final String name;
  final List<Map<String, dynamic>> questions;
}

/// 收集流程里的一道候选题：题库里答错过、可能被收进错题本的题。
class _Candidate {
  _Candidate({
    required this.question,
    required this.bankFile,
    required this.origin,
    required this.legacyOrigin,
  });

  /// 题目 JSON 的浅拷贝；收录时会改写 id / origin / mistakeScore / image。
  final Map<String, dynamic> question;

  /// 题目所在的题库文件，收录时用它定位并复制配图。
  final QuestionBankFile bankFile;

  /// 收录后写进错题本的 origin 键：
  /// - 已迁移题库：稳定随机题目 id（`q_` 开头），与文件位置无关；
  /// - 未迁移题库（id 回写失败）：旧格式 `<文件引用>#<id>`。
  final String origin;

  /// 旧格式的去重键，用于兼容老版本错题本记录；
  /// 未迁移题库里它与 [origin] 相同，重复判断无副作用。
  final String legacyOrigin;
}
