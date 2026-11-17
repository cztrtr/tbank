/// 日志/错误文本脱敏。
///
/// 网络错误、代理返回体、平台异常偶尔会回显请求头。这里统一把 DeepSeek
/// 风格的 Key 替换成 `sk-***`，避免它们进入 SnackBar、debugPrint 或崩溃日志。
class SecretRedactor {
  SecretRedactor._();

  static final RegExp _keyPattern = RegExp(r'sk-[A-Za-z0-9_-]{8,}');

  static String redact(String text) {
    if (text.isEmpty) return text;
    return text.replaceAll(_keyPattern, 'sk-***');
  }

  /// 对可空文本做脱敏。
  static String? redactNullable(String? text) =>
      text == null ? null : redact(text);
}
