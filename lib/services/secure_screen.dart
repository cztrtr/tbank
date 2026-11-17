import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 敏感输入页的屏幕保护。
///
/// Android 通过 `FLAG_SECURE` 阻止截图、录屏和最近任务预览；Windows 暂不
/// 支持（`SetWindowDisplayAffinity` 需要额外的 C++ 实现），调用会静默降级。
class SecureScreen {
  SecureScreen._();

  static const MethodChannel _channel = MethodChannel('tbank/security');

  /// 是否支持在当前平台开启屏幕保护。
  static bool get supported => !kIsWeb && Platform.isAndroid;

  /// 开启/关闭屏幕保护；失败只记日志，不影响输入。
  static Future<void> setEnabled(bool value) async {
    if (!supported) return;
    try {
      await _channel.invokeMethod<bool>('setSecureScreen', <String, bool>{
        'enabled': value,
      });
    } catch (error) {
      debugPrint('设置屏幕保护失败：${error.runtimeType}');
    }
  }
}
