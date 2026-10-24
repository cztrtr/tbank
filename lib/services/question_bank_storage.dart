import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/question_bank.dart';

/// 一个题库文件的读写与同步。
///
/// - load()：把题库文件夹里的源文件复制到文档目录，再解析进内存；
/// - save()：把内存中的整份题库写回文档目录下的副本（每答一题调用）；
/// - syncBack()：把副本回拷到题库所在文件夹。
class QuestionBankStorage {
  QuestionBankStorage({required this.sourcePath, required this.fileName});

  final String sourcePath; // 源文件完整路径
  final String fileName; // 文件名，同时作为文档目录下副本的名字

  File? _workingFile; // 文档目录下的工作副本
  QuestionBank? _bank; // 最近一次加载或保存的题库

  /// 串行队列：保证“写副本”和“回拷”按调用顺序执行，
  /// 不会出现副本只写了一半就被复制回去的情况。
  Future<void> _queue = Future<void>.value();

  /// 工作副本的绝对路径，调试时可以打印出来确认位置。
  String? get workingPath => _workingFile?.path;

  /// 题库 JSON 所在目录的绝对路径。
  ///
  /// 题目的配图就放在这个目录下，文件名记在 `Question.image` 里。
  /// 注意不能用工作副本所在目录：复制到文档目录的只有 JSON，
  /// 图片不会跟着一起复制过去。
  String get sourceDir => File(sourcePath).parent.path;

  /// 最近一次加载或保存的题库；未加载时为 null。
  QuestionBank? get bank => _bank;

  /// 把源文件复制到 getApplicationDocumentsDirectory() 并读取到内存。
  Future<QuestionBank> load() async {
    final docs = await getApplicationDocumentsDirectory();
    final working = File('${docs.path}${Platform.pathSeparator}$fileName');
    final source = File(sourcePath);

    if (!await source.exists()) {
      throw FileSystemException('题库文件不存在', sourcePath);
    }

    // 每次打开都以题库文件夹里的文件为准，覆盖旧副本
    await source.copy(working.path);

    final raw = await working.readAsString();
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('题库文件根节点必须是 JSON 对象');
    }

    final bank = QuestionBank.fromJson(decoded);
    _workingFile = working;
    _bank = bank;
    return bank;
  }

  /// 把内存中的题库写回文档目录下的副本；每答完一题调用一次。
  Future<void> save(QuestionBank bank) {
    _bank = bank;
    return _enqueue(() async {
      final file = _workingFile;
      if (file == null) return;

      // 题目量小，直接整份覆盖写
      final content = const JsonEncoder.withIndent('  ').convert(bank.toJson());
      await file.writeAsString(content, flush: true);
    });
  }

  /// 把工作副本回拷到源文件，返回是否成功。
  Future<bool> syncBack() {
    return _enqueue(() async {
      final file = _workingFile;
      if (file == null) return false;

      try {
        await file.copy(sourcePath);
        return true;
      } catch (error) {
        // 权限被撤销、SD 卡移除、目录被删等都可能走到这里
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
    final result = _queue.then((_) => action());
    _queue = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }
}
