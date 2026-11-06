import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/question_bank.dart';
import '../models/question_bank_file.dart';
import 'bank_io.dart';
import 'ref_hash.dart';

/// 一个题库文件的读写与同步。
///
/// 数据流保持不变：
/// - `load()`：从题库来源读出 JSON，写进 App 文档目录的工作副本，再解析进内存；
/// - `save()`：把内存中的题库写回工作副本（答题过程中调用）；
/// - `syncBack()`：把工作副本内容写回题库来源。
///
/// 工作副本放在 `文档目录/banks/<来源哈希>/<文件名>`：
/// 不同目录下的同名题库各自有独立副本，不会互相覆盖。
/// 副本目录里的 `.dirty` 标记表示「副本比来源新、还没回拷」；
/// 下次 `load()` 会先尝试回拷，失败时直接读副本，避免统计丢失。
class QuestionBankStorage {
  QuestionBankStorage({required this.file});

  /// 当前打开的题库文件。
  final QuestionBankFile file;

  File? _workingFile; // 文档目录下的工作副本
  File? _dirtyFlag; // 副本比来源新的标记，见类注释

  /// 串行队列：保证「写副本」和「回拷」按调用顺序执行，
  /// 不会出现副本只写了一半就被写回题库的情况。
  Future<void> _queue = Future<void>.value();

  /// 上次 [load] 发现的未同步记录提示；null 表示没有。
  ///
  /// 页面可以用它提示用户「上次的答题记录还在本地，等权限恢复后会自动重试」。
  String? _pendingSyncWarning;

  String? get pendingSyncWarning => _pendingSyncWarning;

  /// 题库所在目录的引用。
  ///
  /// 题目配图就放在这个目录下，文件名记在 `Question.image` 里。
  /// 注意不能用工作副本所在目录：复制到文档目录的只有 JSON。
  String get sourceDirectoryRef => file.directoryRef;

  /// 从题库来源读出 JSON，写到文档目录并解析进内存。
  ///
  /// 如果上次回拷失败（`.dirty` 标记还在），先尝试补回拷：
  /// - 成功：按来源文件继续；
  /// - 失败：直接读工作副本（副本里是最新统计），并在
  ///   [pendingSyncWarning] 里留下提示，避免「用旧源文件覆盖新统计」。
  Future<QuestionBank> load() async {
    _pendingSyncWarning = null;

    final Directory docs = await getApplicationDocumentsDirectory();
    final Directory workDir = Directory(
      '${docs.path}${Platform.pathSeparator}banks'
      '${Platform.pathSeparator}${stableRefHash(file.uri)}',
    );
    await workDir.create(recursive: true);

    final File working =
        File('${workDir.path}${Platform.pathSeparator}${file.name}');
    final File dirty =
        File('${workDir.path}${Platform.pathSeparator}.dirty');

    // 上次没回拷成功：先补一次；还不行就读副本，保住宿主答过的统计。
    if (await working.exists() && await dirty.exists()) {
      if (await _writeBack(working)) {
        if (await dirty.exists()) await dirty.delete();
      } else {
        final String raw = await working.readAsString();
        final QuestionBank bank = _decode(raw);
        _workingFile = working;
        _dirtyFlag = dirty;
        _pendingSyncWarning =
            '上次的答题记录还没写回题库文件，已保留在本地；恢复权限后会自动重试。';
        return bank;
      }
    }

    // 正常路径：以题库来源为准，覆盖旧副本
    final String raw = await BankIo.readText(file.uri);

    await working.writeAsString(raw, flush: true);
    if (await dirty.exists()) await dirty.delete();

    final QuestionBank bank = _decode(raw);
    _workingFile = working;
    _dirtyFlag = dirty;
    return bank;
  }

  /// 解析题库 JSON；根节点不是对象时抛出 [FormatException]。
  QuestionBank _decode(String raw) {
    final dynamic decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('题库文件根节点必须是 JSON 对象');
    }
    return QuestionBank.fromJson(decoded);
  }

  /// 把工作副本写回来源，成功返回 true。
  ///
  /// 调用方负责决定失败后的行为；这里只记录日志，不抛异常。
  Future<bool> _writeBack(File working) async {
    try {
      final String content = await working.readAsString();
      await BankIo.writeText(file.uri, content);
      return true;
    } catch (error) {
      // 授权被撤销、目录被删、文件被移走等都可能走到这里
      debugPrint('回拷题库失败：$error');
      return false;
    }
  }

  /// 把内存中的题库写回文档目录下的副本；答题过程中调用。
  Future<void> save(QuestionBank bank) {
    return _enqueue(() async {
      final File? working = _workingFile;
      if (working == null) return;

      // 题目量小，直接整份覆盖写
      final String content =
          const JsonEncoder.withIndent('  ').convert(bank.toJson());
      await working.writeAsString(content, flush: true);
      await _markDirty();
    });
  }

  /// 标记「副本比来源新」，下次打开时优先补回拷。
  ///
  /// 只在第一次写副本时创建标记文件，之后每题保存不再重复写盘。
  Future<void> _markDirty() async {
    final File? dirty = _dirtyFlag;
    if (dirty == null) return;

    try {
      if (!await dirty.exists()) {
        await dirty.writeAsString('1', flush: true);
      }
    } catch (error) {
      // 标记写失败不影响答题，最多下次少一次自动恢复机会
      debugPrint('写入同步标记失败：$error');
    }
  }

  /// 把工作副本内容写回题库来源，返回是否成功。
  ///
  /// 成功后清掉 `.dirty`；失败时保留标记，下次 [load] 会重试。
  Future<bool> syncBack() {
    return _enqueue(() async {
      final File? working = _workingFile;
      if (working == null) return false;

      final bool ok = await _writeBack(working);
      if (!ok) return false;

      final File? dirty = _dirtyFlag;
      if (dirty != null) {
        try {
          if (await dirty.exists()) await dirty.delete();
        } catch (error) {
          debugPrint('清除同步标记失败：$error');
        }
      }
      return true;
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
