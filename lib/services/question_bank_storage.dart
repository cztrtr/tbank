import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/question_bank.dart';
import '../models/question_bank_file.dart';
import 'bank_io.dart';

/// 一个题库文件的读写与同步。
///
/// 数据流保持不变：
/// - `load()`：从题库来源读出 JSON，写进 App 文档目录的工作副本，再解析进内存；
/// - `save()`：把内存中的题库写回工作副本（每答一题调用）；
/// - `syncBack()`：把工作副本内容写回题库来源。
///
/// 区别只在于「题库来源」：Android 上是 SAF 授权的目录，桌面上是普通文件路径，
/// 统一交给 [BankIo] 处理，这里不出现任何路径假设。
class QuestionBankStorage {
  QuestionBankStorage({required this.file});

  /// 当前打开的题库文件。
  final QuestionBankFile file;

  File? _workingFile; // 文档目录下的工作副本
  QuestionBank? _bank; // 最近一次加载或保存的题库

  /// 串行队列：保证「写副本」和「回拷」按调用顺序执行，
  /// 不会出现副本只写了一半就被写回题库的情况。
  Future<void> _queue = Future<void>.value();

  /// 工作副本的绝对路径，调试时可以打印出来确认位置。
  String? get workingPath => _workingFile?.path;

  /// 文件名，同时作为文档目录下副本的名字。
  String get fileName => file.name;

  /// 题库所在目录的引用。
  ///
  /// 题目配图就放在这个目录下，文件名记在 `Question.image` 里。
  /// 注意不能用工作副本所在目录：复制到文档目录的只有 JSON。
  String get sourceDirectoryRef => file.directoryRef;

  /// 最近一次加载或保存的题库；未加载时为 null。
  QuestionBank? get bank => _bank;

  /// 从题库来源读出 JSON，写到文档目录并解析进内存。
  Future<QuestionBank> load() async {
    final Directory docs = await getApplicationDocumentsDirectory();
    final File working =
        File('${docs.path}${Platform.pathSeparator}${file.name}');

    // 读源文件：Android 走 SAF 通道，桌面直接读路径
    final String raw = await BankIo.readText(file.uri);

    // 每次打开都以题库里的文件为准，覆盖旧副本
    await working.writeAsString(raw, flush: true);

    final dynamic decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('题库文件根节点必须是 JSON 对象');
    }

    final QuestionBank bank = QuestionBank.fromJson(decoded);
    _workingFile = working;
    _bank = bank;
    return bank;
  }

  /// 把内存中的题库写回文档目录下的副本；每答完一题调用一次。
  Future<void> save(QuestionBank bank) {
    _bank = bank;
    return _enqueue(() async {
      final File? working = _workingFile;
      if (working == null) return;

      // 题目量小，直接整份覆盖写
      final String content =
          const JsonEncoder.withIndent('  ').convert(bank.toJson());
      await working.writeAsString(content, flush: true);
    });
  }

  /// 把工作副本内容写回题库来源，返回是否成功。
  Future<bool> syncBack() {
    return _enqueue(() async {
      final File? working = _workingFile;
      if (working == null) return false;

      try {
        final String content = await working.readAsString();
        await BankIo.writeText(file.uri, content);
        return true;
      } catch (error) {
        // 授权被撤销、目录被删、文件被移走等都可能走到这里
        debugPrint('回拷题库失败：$error');
        return false;
      }
    });
  }

  /// 把操作排进串行队列：前一个完成后再执行下一个。
  ///
  /// 队列本身吞掉异常，避免一次写失败导致后续任务全部不执行；
  /// 调用方拿到的 result 仍会抛出原始异常。
  Future<T> _enqueue<T>(Future<T> Function() action) {
    final Future<T> result = _queue.then((_) => action());
    _queue = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }
}
