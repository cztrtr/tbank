import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'ds_api_exception.dart';
import 'secret_redactor.dart';

/// DeepSeek 的 HTTP 传输层。
///
/// 只负责：发请求、读响应、把 HTTP 错误翻译成 [DsApiException]。
/// 提示词、判分、出题等业务逻辑在 `DsApiService` 里，两层可以分开测试。
class DsTransport {
  DsTransport._();

  /// 复用同一个 Client：AI 请求通常连续多次，复用连接可以省掉重复 TLS 握手。
  static final http.Client _client = http.Client();

  /// 对 429/5xx 做有限重试；总次数（含首次）= 3。
  static const int _maxAttempts = 3;

  /// 非流式请求：一次性拿到完整回答。
  static Future<String> chatOnce(
    Uri uri,
    Map<String, String> headers,
    Map<String, dynamic> payload,
    Duration timeout,
  ) async {
    final http.Client client = _client;
    try {
      final http.Response response = await _postWithRetry(
        client,
        uri,
        headers,
        payload,
        timeout,
      );

      final String body = utf8.decode(response.bodyBytes, allowMalformed: true);

      if (response.statusCode != 200) {
        throw _httpError(response.statusCode, body);
      }

      final dynamic json = jsonDecode(body);

      final String content = _extractMessageField(json, 'content');
      if (content.isEmpty) {
        throw DsApiException(
          'DeepSeek 返回了空回答',
          body: SecretRedactor.redact(body),
        );
      }
      // 输出被 max_tokens 截断时，JSON 往往缺右括号；明确报错，
      // 让出题器可以缩小批量后重试。
      if (_extractFinishReason(json) == 'length') {
        throw DsApiException(
          'DeepSeek 输出被截断，请重试或减少一次生成的题数',
          body: SecretRedactor.redact(body),
        );
      }
      return content;
    } on DsApiException {
      rethrow;
    } on TimeoutException {
      throw DsApiException('请求超时（${timeout.inSeconds} 秒），请检查网络后重试');
    } on http.ClientException catch (error) {
      throw DsApiException('网络请求失败：${error.message}');
    } catch (error) {
      throw DsApiException('请求失败：$error');
    }
  }

  /// 非流式请求的有限重试：429/5xx 按指数退避，最多 3 次。
  static Future<http.Response> _postWithRetry(
    http.Client client,
    Uri uri,
    Map<String, String> headers,
    Map<String, dynamic> payload,
    Duration timeout,
  ) async {
    Duration wait = const Duration(seconds: 1);
    for (int attempt = 1; ; attempt++) {
      final http.Response response = await client
          .post(uri, headers: headers, body: jsonEncode(payload))
          .timeout(timeout);
      if (!_shouldRetry(response.statusCode) || attempt >= _maxAttempts) {
        return response;
      }
      final String? retryAfter = response.headers['retry-after'];
      final int? seconds = retryAfter == null
          ? null
          : int.tryParse(retryAfter.trim());
      await Future<void>.delayed(
        seconds == null ? wait : Duration(seconds: seconds.clamp(1, 10)),
      );
      wait *= 2;
    }
  }

  static bool _shouldRetry(int statusCode) =>
      statusCode == 429 ||
      statusCode == 500 ||
      statusCode == 502 ||
      statusCode == 503 ||
      statusCode == 504;

  /// 取出 choices[0].finish_reason（`length` 表示输出被截断）。
  static String _extractFinishReason(dynamic json) {
    if (json is! Map) return '';
    final dynamic choices = json['choices'];
    if (choices is! List || choices.isEmpty) return '';
    final dynamic first = choices.first;
    if (first is! Map) return '';
    final dynamic value = first['finish_reason'];
    return value is String ? value : '';
  }

  /// 取出 choices[0].message 下的某个字符串字段。
  static String _extractMessageField(dynamic json, String field) {
    if (json is! Map) return '';

    final dynamic choices = json['choices'];
    if (choices is! List || choices.isEmpty) return '';

    final dynamic first = choices.first;
    if (first is! Map) return '';

    final dynamic message = first['message'];
    if (message is! Map) return '';

    final dynamic value = message[field];
    return value is String ? value.trim() : '';
  }

  /// 把 HTTP 错误码翻译成可读提示。
  static DsApiException _httpError(int statusCode, String body) {
    final String safeBody = SecretRedactor.redact(body);
    final String detail = _errorMessage(safeBody);

    switch (statusCode) {
      case 400:
        return DsApiException(
          '请求参数有误（400）：$detail',
          statusCode: statusCode,
          body: safeBody,
        );
      case 401:
        return DsApiException(
          'API Key 无效或已失效（401），请在设置里重新填写',
          statusCode: statusCode,
          body: safeBody,
        );
      case 402:
        return DsApiException(
          '账户余额不足（402），请到 DeepSeek 平台充值',
          statusCode: statusCode,
          body: safeBody,
        );
      case 422:
        return DsApiException(
          '请求格式错误（422）：$detail',
          statusCode: statusCode,
          body: safeBody,
        );
      case 429:
        return DsApiException(
          '请求过于频繁（429），请稍后再试',
          statusCode: statusCode,
          body: safeBody,
        );
      case 500:
        return DsApiException(
          'DeepSeek 服务异常（500），请稍后重试',
          statusCode: statusCode,
          body: safeBody,
        );
      case 503:
        return DsApiException(
          'DeepSeek 服务繁忙（503），请稍后重试',
          statusCode: statusCode,
          body: safeBody,
        );
      default:
        return DsApiException(
          '请求失败（$statusCode）：$detail',
          statusCode: statusCode,
          body: safeBody,
        );
    }
  }

  /// 尽量从响应体里挖出接口给的错误说明。
  static String _errorMessage(String body) {
    try {
      final dynamic json = jsonDecode(body);
      if (json is Map) {
        final dynamic error = json['error'];
        if (error is Map) {
          final dynamic message = error['message'];
          if (message is String && message.isNotEmpty) return message;
        }
        final dynamic message = json['message'];
        if (message is String && message.isNotEmpty) return message;
      }
    } catch (_) {
      // 不是 JSON 就直接截断原文
    }

    final String text = body.trim();
    if (text.isEmpty) return '（响应体为空）';
    return text.length > 200 ? '${text.substring(0, 200)}…' : text;
  }
}
