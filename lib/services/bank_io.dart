import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/question_bank_file.dart';
import 'saf.dart';

/// 题库文件的统一读写入口。
///
/// 屏蔽两种存储形态的差异：
/// - **Android**：SAF，用户在系统目录选择器里授权过的 `content://` 目录；
/// - **桌面**（Windows）：普通文件路径。
///
/// 判断依据只有一条：引用字符串是否以 `content://` 开头。
/// 因此上层拿到的 `directoryRef` / `uri` 都是一段不透明字符串，不需要关心来源。
class BankIo {
  BankIo._();

  /// 这个引用是不是 SAF 的 content URI。
  static bool _isSafRef(String ref) => ref.startsWith('content://');

  /// 列出目录下的 `.json`，按「子目录 + 文件名」排序。
  ///
  /// [recursive] 为 true 时额外向下扫一层子目录（跳过 `.` 开头的隐藏目录），
  /// 子目录文件带 `sourceDirectoryRef` / `subDirectory`，配图和回拷仍指向
  /// 文件实际所在的子目录。目录不可用时抛出异常，由调用方转成界面提示。
  static Future<List<QuestionBankFile>> listJsonFiles(
    String directoryRef, {
    String? directoryName,
    bool recursive = false,
  }) async {
    if (_isSafRef(directoryRef)) {
      final List<SafEntry> entries = await Saf.listChildren(
        directoryRef,
        extension: '.json',
        recursive: recursive,
      );

      final List<QuestionBankFile> files = entries
          .map(
            (SafEntry entry) => QuestionBankFile(
              name: entry.name,
              uri: entry.uri,
              directoryRef: entry.parentUri ?? directoryRef,
              sourceDirectoryRef: directoryRef,
              subDirectory: entry.subDirectory,
              directoryName: _combinedDirectoryName(
                directoryName,
                entry.subDirectory,
              ),
            ),
          )
          .toList();

      files.sort(_compareFiles);
      return files;
    }

    // 桌面端：普通目录
    final Directory dir = Directory(directoryRef);
    if (!await dir.exists()) {
      throw FileSystemException('目录不存在', directoryRef);
    }

    final List<File> rootFiles = <File>[];
    final List<Directory> subDirs = <Directory>[];
    await for (final FileSystemEntity entity
        in dir.list(followLinks: false)) {
      if (entity is File) {
        rootFiles.add(entity);
      } else if (entity is Directory && recursive) {
        final String name = _lastPathSegment(entity.path);
        if (!name.startsWith('.')) subDirs.add(entity);
      }
    }

    final List<QuestionBankFile> files = <QuestionBankFile>[];

    void addFile(File file, String fileDirectory, String subDirectory) {
      if (!file.path.toLowerCase().endsWith('.json')) return;
      files.add(
        QuestionBankFile(
          name: _lastPathSegment(file.path),
          uri: file.path,
          directoryRef: fileDirectory,
          sourceDirectoryRef: directoryRef,
          subDirectory: subDirectory,
          directoryName: _combinedDirectoryName(
            directoryName,
            subDirectory,
          ),
        ),
      );
    }

    for (final File file in rootFiles) {
      addFile(file, directoryRef, '');
    }

    for (final Directory subDir in subDirs) {
      final String subDirectory = _lastPathSegment(subDir.path);
      try {
        await for (final FileSystemEntity entity
            in subDir.list(followLinks: false)) {
          if (entity is File) {
            addFile(entity, subDir.path, subDirectory);
          }
        }
      } catch (error) {
        // 单个子目录读不了不影响根目录和其它子目录
        debugPrint('扫描子目录失败：${subDir.path} $error');
      }
    }

    files.sort(_compareFiles);
    return files;
  }

  /// 根目录名 + 子目录名；递归文件在统计/错题本里按子目录分组。
  static String? _combinedDirectoryName(String? rootName, String sub) {
    if (rootName == null) return null;
    return sub.isEmpty ? rootName : '$rootName/$sub';
  }

  /// 按根文件的名字、子目录文件的「子目录/名字」排序，根文件顺序和以前一致。
  static int _compareFiles(QuestionBankFile a, QuestionBankFile b) {
    final String left =
        a.subDirectory.isEmpty ? a.name : '${a.subDirectory}/${a.name}';
    final String right =
        b.subDirectory.isEmpty ? b.name : '${b.subDirectory}/${b.name}';
    return left.toLowerCase().compareTo(right.toLowerCase());
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

  /// 在题库目录里写入（或覆盖）一个同名 JSON 文件。
  ///
  /// 与 [writeText] 的区别：这里只在“目录 + 文件名”层面写，不经过已有的
  /// document URI，因此可以创建新文件（AI 变式题会用到）。
  static Future<void> writeSiblingText(
    String directoryRef,
    String fileName,
    String text,
  ) async {
    if (_isSafRef(directoryRef)) {
      await Saf.writeChildText(directoryRef, fileName, text);
      return;
    }

    final File file = File('$directoryRef${Platform.pathSeparator}$fileName');
    await file.writeAsString(text, flush: true);
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
  ///
  /// SAF 的 tree id 里可能带多级路径（`primary:tbankQuestion/医用物理学`），
  /// 这里只取最后一段：展示名、错题本分组名都拿它当文件夹名用，
  /// 带 `/` 的返回值会把“目录名”变成“子目录路径”，导致文件名非法。
  static String displayNameOf(String directoryRef) {
    if (_isSafRef(directoryRef)) {
      final String decoded = Uri.decodeComponent(directoryRef);
      final int colon = decoded.lastIndexOf(':');
      if (colon >= 0 && colon < decoded.length - 1) {
        return _lastPathSegment(decoded.substring(colon + 1));
      }
      return _lastPathSegment(decoded);
    }

    return _lastPathSegment(directoryRef);
  }

  /// 目录引用的「上一级文件夹」信息，供管理页按父目录分组。
  ///
  /// 返回分组键 [key] 与展示名 [label]；解析不出父级（存储根、相对路径、
  /// 异常 URI）时返回 null，由调用方退化成「该目录自己就是一组」。
  ///
  /// - 路径例：`D:\题库\高数` → key `path:D:/题库`，label `题库`
  /// - SAF 例：`...tree/primary%3A题库%2F高数` → key `saf:primary:题库`，
  ///   label `题库`
  static ({String key, String label})? parentOf(String directoryRef) {
    if (_isSafRef(directoryRef)) return _safParentOf(directoryRef);
    return _pathParentOf(directoryRef);
  }

  /// 桌面路径的父目录；`D:\` 这类根目录返回 null。
  static ({String key, String label})? _pathParentOf(String ref) {
    final String normalized = ref
        .replaceAll('\\', '/')
        .replaceFirst(RegExp(r'/+$'), '');
    final int slash = normalized.lastIndexOf('/');
    if (slash <= 0) return null;
    final String parent = normalized.substring(0, slash);
    final String label = _lastPathSegment(parent);
    if (label.isEmpty) return null;
    return (key: 'path:$parent', label: label);
  }

  /// SAF 目录的父目录。
  ///
  /// SAF 的 tree id 形如 `primary:tbankQuestion/大学物理`：
  /// 冒号前是存储卷，后面是卷内路径；去掉最后一段就是父目录。
  static ({String key, String label})? _safParentOf(String ref) {
    final String decoded = Uri.decodeComponent(ref);
    const String marker = '/tree/';
    final int treeIndex = decoded.indexOf(marker);
    if (treeIndex < 0) return null;

    final String tail = decoded
        .substring(treeIndex + marker.length)
        .replaceFirst(RegExp(r'/+$'), '');
    final int colon = tail.indexOf(':');
    final String volume = colon >= 0 ? tail.substring(0, colon) : '';
    final String path = colon >= 0 ? tail.substring(colon + 1) : tail;
    final List<String> parts = path
        .split('/')
        .where((String part) => part.isNotEmpty)
        .toList();

    // 直接授权了整个存储卷：父级就是卷本身
    if (parts.isEmpty) {
      return (key: 'saf:$volume', label: volume.isEmpty ? '/' : volume);
    }

    parts.removeLast();
    final String parentPath = parts.join('/');
    final String label = parts.isEmpty
        ? (volume.isEmpty ? '/' : volume)
        : parts.last;
    return (key: 'saf:$volume/$parentPath', label: label);
  }

  /// 取路径（SAF 的 `/` 或桌面的 `\`）的最后一段。
  static String _lastPathSegment(String path) {
    final List<String> parts = path
        .split(RegExp(r'[\\/]'))
        .where((String s) => s.isNotEmpty)
        .toList();
    return parts.isEmpty ? path : parts.last;
  }

  /// 取文件引用所在的目录（纯字符串处理，不做 IO）。
  ///
  /// 页面构造 `QuestionBankFile` 时用它拿 `directoryRef`，不要直接
  /// `File(path).parent`，这样页面不需要碰 `dart:io`。
  static String directoryOfFile(String fileRef) {
    final int index = fileRef.replaceAll('\\', '/').lastIndexOf('/');
    if (index <= 0) return fileRef;
    // 替换分隔符不改变字符串长度，可以直接用原串截取，保留原来的 \ 或 /
    return fileRef.substring(0, index);
  }

  /// 去掉 UTF-8 BOM；带 BOM 的文本会让 jsonDecode 直接失败。
  static String stripBom(String text) =>
      text.startsWith('\uFEFF') ? text.substring(1) : text;
}
