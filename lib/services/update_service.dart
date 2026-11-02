import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// 应用更新失败时抛出的异常，[message] 可直接展示给用户。
class UpdateException implements Exception {
  const UpdateException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 手动更新：从用户填写的 cpolar 地址下载 `app-release.apk`，并拉起系统安装器。
///
/// 只在 Android 上支持「下载后直接安装」；桌面端只能下载到本地，
/// 由用户自己打开文件。
class UpdateService {
  UpdateService._();

  /// 服务器上的 APK 文件名（与构建产物一致）。
  static const String apkFileName = 'app-release.apk';

  /// 原生安装通道，见 MainActivity.kt。
  static const MethodChannel _channel = MethodChannel('tbank/app_update');

  /// 当前平台是否支持下载后直接拉起安装器。
  static bool get supportsInstall => !kIsWeb && Platform.isAndroid;

  /// 把用户输入整理成 APK 的下载地址。
  ///
  /// 支持三种写法：
  /// - 完整 APK 地址：`https://xxx.r9.cpolar.top/app-release.apk`
  /// - 只填服务器：`https://xxx.r9.cpolar.top`（自动补 `/app-release.apk`）
  /// - 不带协议：`xxx.r9.cpolar.top`（自动补 `https://`）
  static Uri apkUri(String input) {
    String text = input.trim();
    if (text.isEmpty) {
      throw const UpdateException('请先填写更新地址');
    }
    if (!text.contains('://')) {
      text = 'https://$text';
    }

    final Uri base;
    try {
      base = Uri.parse(text);
    } on FormatException {
      throw const UpdateException('地址格式不正确');
    }
    if (base.host.isEmpty) {
      throw const UpdateException('地址格式不正确，请填完整域名');
    }

    if (base.path.toLowerCase().endsWith('.apk')) {
      return base;
    }

    final String dir = base.path.endsWith('/') ? base.path : '${base.path}/';
    return base.replace(path: '${dir}app-release.apk');
  }

  /// 下载 APK 到本机，返回保存的文件。
  ///
  /// [onProgress] 每收到一块数据回调一次；服务器没给 Content-Length 时
  /// total 为 null。
  static Future<File> download({
    required String input,
    void Function(int received, int? total)? onProgress,
  }) async {
    final Uri uri = apkUri(input);
    final Directory dir = await _downloadDirectory();
    final File file = File('${dir.path}${Platform.pathSeparator}$apkFileName');

    final http.Client client = http.Client();
    try {
      final http.StreamedResponse response = await client
          .send(http.Request('GET', uri))
          .timeout(const Duration(seconds: 30));

      if (response.statusCode != 200) {
        throw UpdateException('下载失败（HTTP ${response.statusCode}），请检查地址是否正确');
      }

      final int? total = response.contentLength;
      if (await file.exists()) {
        await file.delete();
      }

      final IOSink sink = file.openWrite();
      int received = 0;
      try {
        await for (final List<int> chunk in response.stream.timeout(
          const Duration(minutes: 2),
        )) {
          sink.add(chunk);
          received += chunk.length;
          onProgress?.call(received, total);
        }
      } finally {
        await sink.close();
      }

      if (received == 0) {
        await file.delete();
        throw const UpdateException('下载内容为空，请检查地址');
      }
      if (total != null && received != total) {
        await file.delete();
        throw const UpdateException('下载不完整，请重试');
      }
      return file;
    } on UpdateException {
      rethrow;
    } on TimeoutException {
      throw const UpdateException('下载超时，请检查网络后重试');
    } on http.ClientException catch (error) {
      throw UpdateException('网络请求失败：${error.message}');
    } catch (error) {
      throw UpdateException('下载失败：$error');
    } finally {
      client.close();
    }
  }

  /// 调起系统安装器（仅 Android）。
  ///
  /// 返回：
  /// - `ok`：已打开安装界面；
  /// - `permission`：缺少「安装未知应用」权限，已跳到系统设置；
  /// - `unsupported`：当前平台不支持直接安装。
  static Future<String> install(File file) async {
    if (!supportsInstall) return 'unsupported';
    final String? result = await _channel.invokeMethod<String>(
      'installApk',
      <String, dynamic>{'path': file.path},
    );
    return result ?? 'error';
  }

  /// 下载目录：Android 用缓存目录（FileProvider 已配置），桌面用下载目录。
  static Future<Directory> _downloadDirectory() async {
    final Directory base;
    if (Platform.isAndroid) {
      base = await getTemporaryDirectory();
    } else {
      base = await getDownloadsDirectory() ?? await getTemporaryDirectory();
    }

    final Directory dir = Directory(
      '${base.path}${Platform.pathSeparator}updates',
    );
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }
}
