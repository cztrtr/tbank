import 'dart:io';

import 'package:flutter/foundation.dart';

/// 原子写文件：先写同目录临时文件，再替换目标文件，并保留一份 `.bak`。
///
/// 背景：配置文件和题库 JSON 都只有一份「正本」。直接
/// `File.writeAsString()` 在写到一半时崩溃/断电，会留下半截 JSON，
/// 用户会同时丢配置和答题统计。
///
/// 这里的实现只覆盖普通文件路径（桌面端和 App 私有目录）。Android 的
/// SAF 文档由 `MainActivity.kt` 里的备份/回滚逻辑兜底——部分文档提供方
/// 不支持 rename，无法做到严格的原子替换。
class AtomicWrite {
  AtomicWrite._();

  /// 临时文件后缀。带上进程内递增序号，避免同一毫秒内两次写入互相覆盖。
  static int _tempSeq = 0;

  /// 把 [text] 原子写入 [path]。
  ///
  /// - [backup] 为 true 时，成功替换后旧内容会留在 `<path>.bak`；
  /// - 替换失败时尽量把 `.bak` 还原回目标文件，再抛出原异常；
  /// - 临时文件在 finally 中清理，不会留在用户目录里。
  static Future<void> writeText(
    String path,
    String text, {
    bool backup = true,
  }) async {
    final File target = File(path);
    await target.parent.create(recursive: true);

    final String tempPath =
        '$path.tmp-${DateTime.now().microsecondsSinceEpoch}-${_tempSeq++}';
    final File temp = File(tempPath);
    final File backupFile = File('$path.bak');

    try {
      await temp.writeAsString(text, flush: true);

      bool hasBackup = false;
      if (await target.exists()) {
        if (backup) {
          // 先删旧备份，避免 rename 在 Windows 上因目标存在而失败。
          if (await backupFile.exists()) await backupFile.delete();
          await target.rename(backupFile.path);
          hasBackup = true;
        } else {
          await target.delete();
        }
      }

      try {
        await temp.rename(path);
      } catch (error) {
        // 替换失败：优先把备份还回去，保证用户至少还有旧文件。
        if (hasBackup && await backupFile.exists()) {
          try {
            await backupFile.rename(path);
          } catch (restoreError) {
            debugPrint('原子写恢复备份失败：$restoreError');
          }
        }
        rethrow;
      }
    } finally {
      if (await temp.exists()) {
        try {
          await temp.delete();
        } catch (error) {
          debugPrint('清理原子写临时文件失败：$error');
        }
      }
    }
  }

  /// 读取 [path]；目标不存在或为空时尝试 `<path>.bak`。
  ///
  /// 返回值里的 [usedBackup] 供调用方提示用户「正在使用备份文件」。
  static Future<AtomicReadResult?> readTextWithBackup(String path) async {
    final File target = File(path);
    try {
      if (await target.exists()) {
        final String text = await target.readAsString();
        if (text.trim().isNotEmpty) {
          return AtomicReadResult(text: text, usedBackup: false);
        }
      }
    } catch (error) {
      debugPrint('读取文件失败，尝试备份：$error');
    }

    final File backup = File('$path.bak');
    try {
      if (await backup.exists()) {
        final String text = await backup.readAsString();
        if (text.trim().isNotEmpty) {
          return AtomicReadResult(text: text, usedBackup: true);
        }
      }
    } catch (error) {
      debugPrint('读取备份文件失败：$error');
    }
    return null;
  }

  /// 只读取 `<path>.bak`；不存在或为空时返回 null。
  static Future<String?> readBackupText(String path) async {
    final File backup = File('$path.bak');
    try {
      if (!await backup.exists()) return null;
      final String text = await backup.readAsString();
      return text.trim().isEmpty ? null : text;
    } catch (error) {
      debugPrint('读取备份文件失败：${error.runtimeType}');
      return null;
    }
  }

  /// 删除 `<path>.bak`。
  ///
  /// 迁移 API Key 后必须调用：旧配置备份里可能还留着 base64 密文。
  static Future<void> deleteBackup(String path) async {
    final File backup = File('$path.bak');
    try {
      if (await backup.exists()) await backup.delete();
    } catch (error) {
      debugPrint('删除备份文件失败：$error');
    }
  }
}

/// [AtomicWrite.readTextWithBackup] 的返回值。
class AtomicReadResult {
  const AtomicReadResult({required this.text, required this.usedBackup});

  final String text;

  /// true 表示目标文件不可用，内容来自 `<path>.bak`。
  final bool usedBackup;
}
