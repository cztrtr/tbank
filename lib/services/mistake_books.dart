// 错题本：把各题库里答错过的题收集到 App 私有目录，单独练。
//
// 存储布局（App Support 目录下）：
//   mistakes/
//     Alpha.json   // 一本最多 25 题
//     Beta.json
//     C001.png     // 错题自带配图，复制过来并按错题编号重命名
//
// 错题本里的每道题比普通题库多两个字段：
//   origin       来源 `<原题库文件引用>#<原题目 id>`，用于去重
//   mistakeScore 还需答对几次才算完成：收集时 5，答对 -1、答错 +1
import 'dart:convert';
import 'dart:io';

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

  /// 刚收进错题本时「还需要答对几次」。
  static const int initialScore = 5;

  /// 本子命名顺序：先占满 24 个希腊字母，再接十二地支；
  /// 一轮用完后加序号（Alpha 2、子 2……）。
  static const List<String> _names = <String>[
    // 希腊字母（24 个）
    'Alpha', 'Beta', 'Gamma', 'Delta', 'Epsilon', 'Zeta',
    'Eta', 'Theta', 'Iota', 'Kappa', 'Lambda', 'Mu',
    'Nu', 'Xi', 'Omicron', 'Pi', 'Rho', 'Sigma',
    'Tau', 'Upsilon', 'Phi', 'Chi', 'Psi', 'Omega',
    // 十二地支（12 个）
    '子', '丑', '寅', '卯', '辰', '巳',
    '午', '未', '申', '酉', '戌', '亥',
  ];

  static String _nameFor(int index) {
    final int cycle = index ~/ _names.length;
    final String base = _names[index % _names.length];
    return cycle == 0 ? base : '$base ${cycle + 1}';
  }

  /// 本子的排序权重，保证 Alpha……Omega、子……亥 按期望顺序排列。
  ///
  /// 兼容带序号的名字（`Alpha 2`、`子 2`）。
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

      books.add(MistakeBookInfo(
        name: book.name,
        path: file.path,
        total: book.questions.length,
        completed: completed,
      ));
    }
    return books;
  }

  /// 扫描所有题库，把答错过的题收进错题本，返回本次新增的题目数。
  ///
  /// 已经收集过的题（按 `origin` 判断）不会重复加入；
  /// 配图会一起复制过来，并按错题编号重命名。
  static Future<int> collectFromBanks() async {
    final Directory dir = await directory();

    // 1. 读出现有本子：已收集的来源、最大错题编号
    final List<_BookData> books = <_BookData>[];
    final Set<String> knownOrigins = <String>{};
    int maxNumber = 0;

    for (final File file in _jsonFiles(dir)) {
      final _BookData? book = await _readBook(file);
      if (book == null) continue;
      books.add(book);

      for (final Map<String, dynamic> question in book.questions) {
        final String origin = question['origin']?.toString() ?? '';
        if (origin.isNotEmpty) knownOrigins.add(origin);

        final RegExpMatch? match =
            RegExp(r'^C(\d+)$').firstMatch(question['id']?.toString() ?? '');
        if (match != null) {
          final int number = int.parse(match.group(1)!);
          if (number > maxNumber) maxNumber = number;
        }
      }
    }

    // 2. 遍历题库目录，挑出答错且没收集过的题
    final List<Map<String, dynamic>> pending = <Map<String, dynamic>>[];

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

        for (final dynamic item in rawQuestions) {
          if (item is! Map) continue;
          final Map<String, dynamic> question =
              Map<String, dynamic>.from(item);

          // 只收答错过的题
          final dynamic stats = question['stats'];
          final int wrongCount = (stats is Map && stats['wrongCount'] is num)
              ? (stats['wrongCount'] as num).toInt()
              : 0;
          if (wrongCount <= 0) continue;

          final String origin = '${bankFile.uri}#${question['id']}';
          if (!knownOrigins.add(origin)) continue; // 已收集过

          maxNumber++;
          final String newId = 'C${maxNumber.toString().padLeft(3, '0')}';

          question['id'] = newId;
          question['origin'] = origin;
          question['mistakeScore'] = initialScore;
          question['image'] = await _copyImage(
            dir,
            bankFile,
            question['image'],
            newId,
          );

          pending.add(question);
        }
      }
    }

    if (pending.isEmpty) return 0;

    // 3. 先填已有本子的空位，剩下的按每本 25 题新建
    final List<Map<String, dynamic>> remaining =
        List<Map<String, dynamic>>.of(pending);

    for (final _BookData book in books) {
      while (book.questions.length < perBook && remaining.isNotEmpty) {
        book.questions.add(remaining.removeAt(0));
      }
      if (remaining.isEmpty) break;
    }

    int nextIndex = books.length;
    while (remaining.isNotEmpty) {
      final List<Map<String, dynamic>> slice = <Map<String, dynamic>>[];
      while (slice.length < perBook && remaining.isNotEmpty) {
        slice.add(remaining.removeAt(0));
      }
      books.add(_BookData(name: _nameFor(nextIndex), questions: slice));
      nextIndex++;
    }

    // 4. 写回所有本子
    for (final _BookData book in books) {
      await _writeBook(dir, book.name, book.questions);
    }
    return pending.length;
  }

  // ---------------------------------------------------------------- 内部

  /// 目录下的 `.json` 文件，按本名顺序排序。
  static List<File> _jsonFiles(Directory dir) {
    final List<File> files = dir
        .listSync()
        .whereType<File>()
        .where((File file) => file.path.toLowerCase().endsWith('.json'))
        .toList();
    files.sort((File a, File b) =>
        _orderOf(_baseName(a)).compareTo(_orderOf(_baseName(b))));
    return files;
  }

  /// 取文件名（去掉 `.json`）。
  static String _baseName(File file) {
    final String name = file.uri.pathSegments.last;
    return name.toLowerCase().endsWith('.json')
        ? name.substring(0, name.length - 5)
        : name;
  }

  static Future<_BookData?> _readBook(File file) async {
    try {
      final String text =
          BankIo.stripBom(await file.readAsString());
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
      final String text =
          BankIo.stripBom(await BankIo.readText(bankFile.uri));
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
      final Uint8List? bytes =
          await BankIo.readSiblingBytes(bankFile.directoryRef, image);
      if (bytes == null || bytes.isEmpty) return '';

      final int dot = image.lastIndexOf('.');
      final String extension = dot >= 0 ? image.substring(dot) : '.png';
      final String fileName = '$newId$extension';

      final File target =
          File('${dir.path}${Platform.pathSeparator}$fileName');
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
    final String content = const JsonEncoder.withIndent('  ').convert(
      <String, dynamic>{'questions': questions},
    );
    await file.writeAsString(content, flush: true);
  }
}

/// 内存中的一本错题本。
class _BookData {
  _BookData({required this.name, required this.questions});

  final String name;
  final List<Map<String, dynamic>> questions;
}
