import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/question_bank.dart';
import '../models/question_bank_file.dart';
import 'atomic_write.dart';
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
  File? _sourceStamp; // 记录工作副本对应的源文件指纹
  String? _sourceFingerprint;

  /// 编辑题库后通知练习页：当前打开的文件内容已变化，需要重新加载。
  static final ValueNotifier<String?> sourceChangedNotifier =
      ValueNotifier<String?>(null);

  static const String _stampFileName = '.source';
  static const String _invalidStamp = 'invalidated';

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
  ///
  /// 如果源文件在练习期间被其它页面（例如题目编辑器）改过，则以源文件为准，
  /// 丢弃旧工作副本，避免旧副本把新题干/解析覆盖回去。
  Future<QuestionBank> load() async {
    _pendingSyncWarning = null;

    final Directory workDir = await _workDirFor(file);
    await workDir.create(recursive: true);

    final File working = File(
      '${workDir.path}${Platform.pathSeparator}${file.name}',
    );
    final File dirty = File('${workDir.path}${Platform.pathSeparator}.dirty');
    final File stamp = File(
      '${workDir.path}${Platform.pathSeparator}$_stampFileName',
    );

    final String sourceRaw;
    try {
      sourceRaw = await BankIo.readText(file.uri);
    } catch (error) {
      // 源文件暂时读不到（权限撤销、目录被删）：只要还有本地副本，就先用副本。
      if (await working.exists() && await dirty.exists()) {
        final String raw = await working.readAsString();
        final QuestionBank bank = _decode(raw);
        _workingFile = working;
        _dirtyFlag = dirty;
        _sourceStamp = stamp;
        _pendingSyncWarning = '读取题库源文件失败，已加载本地工作副本；恢复权限后会自动重试。';
        return bank;
      }
      rethrow;
    }
    final String sourceFingerprint = stableRefHash(sourceRaw);
    final String? baseline = await _readStamp(stamp);

    // 源文件被其它页面改过：旧副本不能回拷，直接加载新源文件。
    if (await working.exists() &&
        await dirty.exists() &&
        baseline != null &&
        baseline != sourceFingerprint) {
      await working.delete();
      await dirty.delete();
      _pendingSyncWarning = '题库文件在练习期间被修改，已优先加载新内容；旧练习统计未合并。';
    }

    // 指纹缺失（旧版本、指纹文件被清理、写入失败）：不能盲目把旧副本写回，
    // 否则可能覆盖用户后来手动编辑的题干/解析。
    //
    // 桌面端可以用 mtime 判断：源文件比副本新 → 以源文件为准；
    // SAF 没有可靠的 mtime，改为「先加载副本、记录当前源文件指纹」，
    // 之后 syncBack 会再次比对，源文件变过就拒绝覆盖。
    if (await working.exists() &&
        await dirty.exists() &&
        baseline == null &&
        await _sourceLooksNewer(working)) {
      await working.delete();
      await dirty.delete();
      _pendingSyncWarning = '题库文件在练习期间被修改，已优先加载新内容；旧练习统计未合并。';
    }

    // 上次没回拷成功：先补一次；还不行就读副本，保住宿主答过的统计。
    if (await working.exists() && await dirty.exists()) {
      if (baseline == null) {
        // 无法确认副本与源文件的先后关系：保住宿主统计，但不立即回写。
        // 记住当前源文件指纹，后续 syncBack 发现源文件再变就拒绝覆盖。
        final String raw = await working.readAsString();
        final QuestionBank bank = _decode(raw);
        _workingFile = working;
        _dirtyFlag = dirty;
        _sourceStamp = stamp;
        _sourceFingerprint = sourceFingerprint;
        _pendingSyncWarning =
            '无法确认上次的答题记录是否已写回题库文件，已保留本地副本；'
            '下次同步时会再次检查源文件。';
        return bank;
      }
      if (await _writeBack(working)) {
        if (await dirty.exists()) await dirty.delete();
        final String written = await working.readAsString();
        final QuestionBank bank = _decode(written);
        _workingFile = working;
        _dirtyFlag = dirty;
        await _setSourceFingerprint(written, stamp);
        return bank;
      } else {
        final String raw = await working.readAsString();
        final QuestionBank bank = _decode(raw);
        _workingFile = working;
        _dirtyFlag = dirty;
        _sourceStamp = stamp;
        _sourceFingerprint = sourceFingerprint;
        _pendingSyncWarning = '上次的答题记录还没写回题库文件，已保留在本地；恢复权限后会自动重试。';
        return bank;
      }
    }

    // 正常路径：以题库来源为准，覆盖旧副本
    await working.writeAsString(sourceRaw, flush: true);
    if (await dirty.exists()) await dirty.delete();

    final QuestionBank bank = _decode(sourceRaw);
    _workingFile = working;
    _dirtyFlag = dirty;
    await _setSourceFingerprint(sourceRaw, stamp);
    return bank;
  }

  Future<void> _setSourceFingerprint(String raw, File stamp) async {
    _sourceStamp = stamp;
    _sourceFingerprint = stableRefHash(raw);
    await _writeStamp(stamp, _sourceFingerprint!);
  }

  Future<String?> _readStamp(File stamp) async {
    try {
      if (!await stamp.exists()) return null;
      final String value = (await stamp.readAsString()).trim();
      return value.isEmpty ? null : value;
    } catch (error) {
      debugPrint('读取题库源文件指纹失败：$error');
      return null;
    }
  }

  Future<void> _writeStamp(File stamp, String fingerprint) async {
    try {
      await stamp.writeAsString(fingerprint, flush: true);
    } catch (error) {
      debugPrint('写入题库源文件指纹失败：$error');
    }
  }

  static Future<Directory> _workDirFor(QuestionBankFile file) async {
    final Directory docs = await getApplicationDocumentsDirectory();
    return Directory(
      '${docs.path}${Platform.pathSeparator}banks'
      '${Platform.pathSeparator}${stableRefHash(file.uri)}',
    );
  }

  /// 题库编辑器写回源文件后调用：作废旧工作副本，下一次练习必须从源文件重读。
  ///
  /// 保留一个 `invalidated` 指纹；如果此时练习页还活着并重新写了工作副本，
  /// 下次 load 会把这份旧副本识别为过期并丢弃。
  static Future<void> invalidateForFile(QuestionBankFile file) async {
    try {
      final Directory workDir = await _workDirFor(file);
      if (!await workDir.exists()) return;
      final File working = File(
        '${workDir.path}${Platform.pathSeparator}${file.name}',
      );
      final File dirty = File('${workDir.path}${Platform.pathSeparator}.dirty');
      final File stamp = File(
        '${workDir.path}${Platform.pathSeparator}$_stampFileName',
      );
      if (await working.exists()) await working.delete();
      if (await dirty.exists()) await dirty.delete();
      await stamp.writeAsString(_invalidStamp, flush: true);
    } catch (error) {
      debugPrint('作废旧题库副本失败：$error');
    }
  }

  /// 解析题库 JSON；根节点不是对象时抛出 [FormatException]。
  QuestionBank _decode(String raw) => QuestionCodec.decode(raw);

  /// 指纹缺失时，桌面端用 mtime 粗略判断源文件是否比工作副本新。
  ///
  /// SAF 的 content:// 没有可用的 mtime，返回 false，交给上面的
  /// 「保副本 + 记录指纹」分支处理。
  Future<bool> _sourceLooksNewer(File working) async {
    if (file.uri.startsWith('content://')) return false;
    try {
      final DateTime sourceTime = await File(file.uri).lastModified();
      final DateTime workingTime = await working.lastModified();
      return sourceTime.isAfter(workingTime);
    } catch (error) {
      debugPrint('比较题库源文件时间失败：${error.runtimeType}');
      return false;
    }
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

      // 题目量小，直接整份覆盖写；工作副本也用原子写，避免半截 JSON。
      final String content = QuestionCodec.encode(bank);
      await AtomicWrite.writeText(working.path, content);
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
      final File? stamp = _sourceStamp;
      if (working == null) return false;

      final String? expected = _sourceFingerprint;
      if (expected != null) {
        try {
          final String currentSource = await BankIo.readText(file.uri);
          if (stableRefHash(currentSource) != expected) {
            _pendingSyncWarning = '题库文件已在其它位置修改，未覆盖新内容；本次练习统计保留在本地。';
            return false;
          }
        } catch (error) {
          debugPrint('校验题库源文件失败：$error');
          _pendingSyncWarning = '读取题库源文件失败，本次练习统计保留在本地。';
          return false;
        }
      }

      final bool ok = await _writeBack(working);
      if (!ok) return false;

      if (stamp != null) {
        try {
          final String written = await working.readAsString();
          await _setSourceFingerprint(written, stamp);
        } catch (error) {
          debugPrint('更新题库源文件指纹失败：$error');
        }
      }

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
    _queue = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}
