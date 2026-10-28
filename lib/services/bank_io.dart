import 'dart:io';
import 'dart:typed_data';

import '../models/question_bank_file.dart';
import 'saf.dart';

/// 题库文件的统一读写入口。
///
/// 屏蔽两种存储形态的差异：
/// - **Android**：SAF，用户在系统目录选择器里授权过的 `content://` 目录；
/// - **桌面**（Windows，模板保留 macOS）：普通文件路径。
///
/// 判断依据只有一条：引用字符串是否以 `content://` 开头。
/// 因此上层拿到的 `directoryRef` / `uri` 都是一段不透明字符串，不需要关心来源。
class BankIo {
  BankIo._();

  /// 这个引用是不是 SAF 的 content URI。
  static bool _isSafRef(String ref) => ref.startsWith('content://');

  /// 列出目录下所有 `.json`，按文件名升序。
  ///
  /// SAF 和桌面路径都会走这里；目录不可用时抛出异常，由调用方转成界面提示。
  static Future<List<QuestionBankFile>> listJsonFiles(
    String directoryRef, {
    String? directoryName,
  }) async {
    if (_isSafRef(directoryRef)) {
      final List<SafEntry> entries =
          await Saf.listChildren(directoryRef, extension: '.json');

      final List<QuestionBankFile> files = entries
          .map(
            (SafEntry entry) => QuestionBankFile(
              name: entry.name,
              uri: entry.uri,
              directoryRef: directoryRef,
              directoryName: directoryName,
            ),
          )
          .toList();

      files.sort(
        (QuestionBankFile a, QuestionBankFile b) =>
            a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      );
      return files;
    }

    // 桌面端：普通目录
    final Directory dir = Directory(directoryRef);
    if (!await dir.exists()) {
      throw FileSystemException('目录不存在', directoryRef);
    }

    final List<QuestionBankFile> files = <QuestionBankFile>[];
    await for (final FileSystemEntity entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;

      final String name = entity.path.split(Platform.pathSeparator).last;
      if (!name.toLowerCase().endsWith('.json')) continue;

      files.add(
        QuestionBankFile(
          name: name,
          uri: entity.path,
          directoryRef: directoryRef,
          directoryName: directoryName,
        ),
      );
    }

    files.sort(
      (QuestionBankFile a, QuestionBankFile b) =>
          a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );
    return files;
  }

  /// 读取题库 JSON 文本。
  static Future<String> readText(String fileRef) async {
    if (_isSafRef(fileRef)) {
      // 原生侧已经去掉了 BOM
      return Saf.readText(fileRef);
    }
    return stripBom(await File(fileRef).readAsString());
  }

  /// 覆盖写入题库 JSON 文本。
  static Future<void> writeText(String fileRef, String text) async {
    if (_isSafRef(fileRef)) {
      await Saf.writeText(fileRef, text);
      return;
    }
    await File(fileRef).writeAsString(text, flush: true);
  }

  /// 在题库目录里按文件名读取配图字节；找不到返回 null。
  static Future<Uint8List?> readSiblingBytes(
    String directoryRef,
    String fileName,
  ) async {
    if (_isSafRef(directoryRef)) {
      return Saf.readChildBytes(directoryRef, fileName);
    }

    final File file = File('$directoryRef${Platform.pathSeparator}$fileName');
    if (!await file.exists()) return null;
    return file.readAsBytes();
  }

  /// 释放目录授权（仅 SAF 有意义，桌面端是空操作）。
  static Future<void> releaseDirectory(String directoryRef) async {
    if (!_isSafRef(directoryRef)) return;
    try {
      await Saf.releasePermission(directoryRef);
    } catch (_) {
      // 用户可能已在系统设置里撤销，忽略即可
    }
  }

  /// 从目录引用推导一个可展示的名字。
  ///
  /// SAF 例：`content://.../tree/primary%3ABooks` → `Books`
  /// 路径例：`D:\题库` → `题库`
  static String displayNameOf(String directoryRef) {
    if (_isSafRef(directoryRef)) {
      final String decoded = Uri.decodeComponent(directoryRef);
      final int colon = decoded.lastIndexOf(':');
      if (colon >= 0 && colon < decoded.length - 1) {
        return decoded.substring(colon + 1);
      }
      final List<String> segments =
          decoded.split('/').where((String s) => s.isNotEmpty).toList();
      return segments.isEmpty ? decoded : segments.last;
    }

    final List<String> parts = directoryRef
        .split(RegExp(r'[\\/]'))
        .where((String s) => s.isNotEmpty)
        .toList();
    return parts.isEmpty ? directoryRef : parts.last;
  }

  /// 去掉 UTF-8 BOM；带 BOM 的文本会让 jsonDecode 直接失败。
  static String stripBom(String text) =>
      text.startsWith('\uFEFF') ? text.substring(1) : text;
}
