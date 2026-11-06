import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'ds_api_exception.dart';

/// 流式响应里的一小段：可能携带正文，也可能携带思考过程。
class DsStreamDelta {
  const DsStreamDelta({this.content, this.reasoning});

  /// 回答正文（delta.content）。
  final String? content;

  /// 思考过程（delta.reasoning_content），仅启用推理时出现。
  final String? reasoning;

  bool get isEmpty =>
      (content == null || content!.isEmpty) &&
      (reasoning == null || reasoning!.isEmpty);
}

/// DeepSeek 的 HTTP 传输层。
///
/// 只负责：发请求、读响应、解析 SSE、把 HTTP 错误翻译成 [DsApiException]。
/// 提示词、判分、出题等业务逻辑在 `DsApiService` 里，两层可以分开测试。
class DsTransport {
  DsTransport._();

  /// 非流式请求：一次性拿到完整回答。
  static Future<String> chatOnce(
    Uri uri,
    Map<String, String> headers,
    Map<String, dynamic> payload,
    void Function(String delta)? onReasoning,
    Duration timeout,
  ) async {
    final http.Client client = http.Client();
    try {
      final http.Response response = await client
          .post(uri, headers: headers, body: jsonEncode(payload))
          .timeout(timeout);

      final String body = utf8.decode(response.bodyBytes, allowMalformed: true);

      if (response.statusCode != 200) {
        throw _httpError(response.statusCode, body);
      }

      final dynamic json = jsonDecode(body);

      final String reasoning = _extractMessageField(json, 'reasoning_content');
      if (reasoning.isNotEmpty) {
        onReasoning?.call(reasoning);
      }

      final String content = _extractMessageField(json, 'content');
      if (content.isEmpty) {
        throw DsApiException('DeepSeek 返回了空回答', body: body);
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
    } finally {
      client.close();
    }
  }

  /// 流式请求：逐行解析 SSE，正文/思考过程通过回调实时给出。
  static Future<String> chatStream(
    Uri uri,
    Map<String, String> headers,
    Map<String, dynamic> payload,
    void Function(String delta)? onDelta,
    void Function(String delta)? onReasoning,
    Duration timeout,
  ) async {
    final http.Client client = http.Client();
    try {
      final http.Request request = http.Request('POST', uri)
        ..headers.addAll(headers)
        ..body = jsonEncode(payload);

      final http.StreamedResponse response = await client
          .send(request)
          .timeout(timeout);

      if (response.statusCode != 200) {
        final String body = await response.stream.bytesToString();
        throw _httpError(response.statusCode, body);
      }

      final StringBuffer buffer = StringBuffer();

      await for (final String line
          in response.stream
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
        final String trimmed = line.trim();
        if (trimmed.isEmpty) continue;

        // 流结束标记
        if (trimmed == 'data: [DONE]' || trimmed == 'data:[DONE]') break;

        final DsStreamDelta? delta = sseDelta(trimmed);
        if (delta == null || delta.isEmpty) continue;

        final String? reasoning = delta.reasoning;
        if (reasoning != null && reasoning.isNotEmpty) {
          onReasoning?.call(reasoning);
        }

        final String? piece = delta.content;
        if (piece != null && piece.isNotEmpty) {
          buffer.write(piece);
          onDelta?.call(piece);
        }
      }

      final String content = buffer.toString();
      if (content.isEmpty) {
        throw DsApiException('DeepSeek 未返回任何内容，可能是流被中断');
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
    } finally {
      client.close();
    }
  }

  /// 从一行 SSE 中取出增量内容（正文与思考过程）。
  ///
  /// 只处理 `data: {...}` 行；返回 null 表示这行不携带内容
  /// （心跳、role 消息、`[DONE]`、格式错误等）。
  /// 单行解析失败不会中断整个流。
  static DsStreamDelta? sseDelta(String line) {
    if (!line.startsWith('data:')) return null;

    final String data = line.substring(5).trim();
    if (data.isEmpty || data == '[DONE]') return null;

    try {
      final dynamic json = jsonDecode(data);
      if (json is! Map) return null;

      final dynamic choices = json['choices'];
      if (choices is! List || choices.isEmpty) return null;

      final dynamic first = choices.first;
      if (first is! Map) return null;

      final dynamic delta = first['delta'];
      if (delta is! Map) return null;

      final dynamic content = delta['content'];
      final dynamic reasoning = delta['reasoning_content'];

      final String? text = content is String && content.isNotEmpty
          ? content
          : null;
      final String? thought = reasoning is String && reasoning.isNotEmpty
          ? reasoning
          : null;

      if (text == null && thought == null) return null;
      return DsStreamDelta(content: text, reasoning: thought);
    } catch (_) {
      return null;
    }
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
    final String detail = _errorMessage(body);

    switch (statusCode) {
      case 400:
        return DsApiException(
          '请求参数有误（400）：$detail',
          statusCode: statusCode,
          body: body,
        );
      case 401:
        return DsApiException(
          'API Key 无效或已失效（401），请在设置里重新填写',
          statusCode: statusCode,
          body: body,
        );
      case 402:
        return DsApiException(
          '账户余额不足（402），请到 DeepSeek 平台充值',
          statusCode: statusCode,
          body: body,
        );
      case 422:
        return DsApiException(
          '请求格式错误（422）：$detail',
          statusCode: statusCode,
          body: body,
        );
      case 429:
        return DsApiException(
          '请求过于频繁（429），请稍后再试',
          statusCode: statusCode,
          body: body,
        );
      case 500:
        return DsApiException(
          'DeepSeek 服务异常（500），请稍后重试',
          statusCode: statusCode,
          body: body,
        );
      case 503:
        return DsApiException(
          'DeepSeek 服务繁忙（503），请稍后重试',
          statusCode: statusCode,
          body: body,
        );
      default:
        return DsApiException(
          '请求失败（$statusCode）：$detail',
          statusCode: statusCode,
          body: body,
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
