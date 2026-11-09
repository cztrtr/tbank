import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 一个被授权的 SAF 目录。
class SafDirectory {
  const SafDirectory({required this.uri, required this.name});

  /// 持久化的 tree URI，例如 `content://com.android.externalstorage.documents/tree/primary%3ABooks`
  final String uri;

  /// 展示用名称，通常是文件夹名。
  final String name;
}

/// 目录里的一个文件。
class SafEntry {
  const SafEntry({
    required this.name,
    required this.uri,
    this.parentUri,
    this.subDirectory = '',
  });

  final String name;

  /// 文件的 document URI，可直接用于读写。
  final String uri;

  /// 文件所在目录的 document URI；递归扫描子目录时用它读配图、回拷。
  ///
  /// 根目录下的文件为 null（调用方退回授权根目录）。
  final String? parentUri;

  /// 相对授权根目录的子目录名；根目录下的文件为空字符串。
  final String subDirectory;
}

/// Android Storage Access Framework 的 Dart 封装。
///
/// 对应原生侧 `tbank/saf` 通道，见 MainActivity.kt。
/// 所有 IO 都在原生线程池里执行，不会阻塞 UI。
class Saf {
  Saf._();

  static const MethodChannel _channel = MethodChannel('tbank/saf');

  /// SAF 只在 Android 上可用；桌面端继续用文件路径。
  static bool get isSupported => !kIsWeb && Platform.isAndroid;

  /// 弹出系统目录选择器；用户取消返回 null。
  ///
  /// 选中的目录会立刻申请持久授权，重启 App 后依然可读写。
  static Future<SafDirectory?> pickDirectory() async {
    final Map<String, dynamic>? result = await _channel
        .invokeMapMethod<String, dynamic>('pickDirectory');
    if (result == null) return null;

    final String? uri = result['uri'] as String?;
    if (uri == null || uri.isEmpty) return null;

    return SafDirectory(uri: uri, name: (result['name'] as String?) ?? uri);
  }

  /// 列出目录下的文件；`extension` 形如 `.json`，为 null 时不过滤。
  ///
  /// [recursive] 为 true 时额外向下扫一层子目录，返回的子目录文件带
  /// [SafEntry.parentUri] 和 [SafEntry.subDirectory]；跳过 `.` 开头的隐藏目录。
  static Future<List<SafEntry>> listChildren(
    String directoryUri, {
    String? extension,
    bool recursive = false,
  }) async {
    final List<dynamic>? rows = await _channel.invokeListMethod<dynamic>(
      'listChildren',
      <String, dynamic>{
        'uri': directoryUri,
        'ext': extension,
        'recursive': recursive,
      },
    );
    if (rows == null) return <SafEntry>[];

    final List<SafEntry> entries = <SafEntry>[];
    for (final dynamic row in rows) {
      if (row is! Map) continue;
      final String? name = row['name'] as String?;
      final String? uri = row['uri'] as String?;
      if (name == null || uri == null) continue;
      entries.add(
        SafEntry(
          name: name,
          uri: uri,
          parentUri: row['parentUri'] as String?,
          subDirectory: (row['subDirectory'] as String?) ?? '',
        ),
      );
    }
    return entries;
  }

  /// 读取 UTF-8 文本（原生侧已去掉 BOM）。
  static Future<String> readText(String documentUri) async {
    final String? text = await _channel.invokeMethod<String>(
      'readText',
      <String, dynamic>{'uri': documentUri},
    );
    return text ?? '';
  }

  /// 覆盖写入 UTF-8 文本（原生侧用 "wt" 模式，会截断旧内容）。
  static Future<void> writeText(String documentUri, String text) {
    return _channel.invokeMethod<void>('writeText', <String, dynamic>{
      'uri': documentUri,
      'text': text,
    });
  }

  /// 在目录里按文件名找子文件并读成字节；找不到返回 null。
  static Future<Uint8List?> readChildBytes(
    String directoryUri,
    String fileName,
  ) async {
    return _channel.invokeMethod<Uint8List>('readChildBytes', <String, dynamic>{
      'uri': directoryUri,
      'name': fileName,
    });
  }

  /// 在目录里新建（或覆盖）一个 UTF-8 文本文件，返回它的 document URI。
  ///
  /// 同名文件已存在时直接覆盖内容；不存在时用 DocumentsContract.createDocument
  /// 创建。写入的 MIME 固定为 `application/json`。
  static Future<String> writeChildText(
    String directoryUri,
    String fileName,
    String text,
  ) async {
    final String? uri = await _channel.invokeMethod<String>(
      'writeChildText',
      <String, dynamic>{'uri': directoryUri, 'name': fileName, 'text': text},
    );
    return uri ?? '';
  }

  /// 释放某个目录的持久授权（用户移除目录时调用）。
  static Future<void> releasePermission(String directoryUri) {
    return _channel.invokeMethod<void>('releasePermission', <String, dynamic>{
      'uri': directoryUri,
    });
  }
}
