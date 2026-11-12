import 'dart:async';

import 'package:flutter/services.dart';

/// 手写笔系统手势通道。
///
/// Android 侧把小米焦点触控笔 Pro 的手势键码转发过来：
/// 194 轻捏 / 195 双击 / 196 上滑 / 197 下滑。
/// 目前插件只消费 195（切换笔 / 橡皮），其余键码先保留。
///
/// 非小米设备没有这条通道，事件流一直为空，插件退回笔尖双击兜底。
class PenGesture {
  PenGesture._();

  static const MethodChannel _channel = MethodChannel('tbank/pen_gesture');

  static final StreamController<int> _events =
      StreamController<int>.broadcast();

  static bool _initialized = false;

  /// 手势键码事件流；只有插件练习页需要监听。
  static Stream<int> get events => _events.stream;

  /// 在 main() 里调用一次，之后 Android 侧的按键才会被接收。
  static void init() {
    if (_initialized) return;
    _initialized = true;
    _channel.setMethodCallHandler((MethodCall call) async {
      if (call.method != 'key') return null;
      final Object? raw = call.arguments;
      final int code = raw is int ? raw : int.tryParse('$raw') ?? 0;
      if (code >= 194 && code <= 197) _events.add(code);
      return true;
    });
  }
}
