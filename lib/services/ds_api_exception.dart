/// DeepSeek API 调用失败时抛出的异常。
///
/// 界面直接 `catch (DsApiException e)` 即可拿到可读的中文提示。
class DsApiException implements Exception {
  DsApiException(this.message, {this.statusCode, this.body});

  /// 可直接展示给用户的提示。
  final String message;

  /// HTTP 状态码；网络层失败时为 null。
  final int? statusCode;

  /// 原始响应体，排查问题时用。
  final String? body;

  @override
  String toString() => message;
}
