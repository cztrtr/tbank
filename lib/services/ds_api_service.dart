import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'app_config.dart';

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

/// DeepSeek 对话 API 的封装（OpenAI 兼容协议），固定使用 `deepseek-flash`。
///
/// 用法：
/// ```dart
/// // 非流式，关闭推理
/// final a = await DsApiService.ask('什么是间皮？', stream: false, thinking: false);
///
/// // 流式，启用推理
/// final b = await DsApiService.ask(
///   '为什么这题选 B？',
///   stream: true,
///   thinking: true,
///   onDelta: (chunk) => setState(() => _answer += chunk),
///   onReasoning: (chunk) => setState(() => _thinking += chunk),
/// );
/// ```
///
/// 失败时抛出 [DsApiException]。
class DsApiService {
  DsApiService._();

  /// 唯一使用的模型。
  static const String model = 'deepseek-flash';

  static const String _baseUrl = 'https://api.deepseek.com';

  /// 请求超时时间；启用推理时产出较长，不宜过短。
  static const Duration _timeout = Duration(seconds: 120);

  /// 发起一次对话，返回完整回答文本。
  ///
  /// - [content]：要询问的内容；
  /// - [stream]：是否流式输出。为 true 时每收到一段就调用 [onDelta]，
  ///   同时把全文累积起来作为返回值；
  /// - [thinking]：是否启用推理（思考模式）。启用后模型会先输出思考过程，
  ///   通过 [onReasoning] 回调给出（非流式时为一次性整段）。
  ///
  /// API Key 取自 `AppConfig.dsApiKey`，未配置时直接抛异常。
  static Future<String> ask(
    String content, {
    required bool stream,
    required bool thinking,
    void Function(String delta)? onDelta,
    void Function(String delta)? onReasoning,
  }) async {
    final String question = content.trim();
    if (question.isEmpty) {
      throw DsApiException('问题内容不能为空');
    }
    return _send(
      question,
      stream: stream,
      thinking: thinking,
      onDelta: onDelta,
      onReasoning: onReasoning,
    );
  }

  /// 真正发请求的地方。
  ///
  /// [content] 可以是纯字符串，也可以是 OpenAI 兼容的内容块数组
  /// （带图片时使用，见 [scoreAnswer]）。
  static Future<String> _send(
    Object content, {
    required bool stream,
    required bool thinking,
    void Function(String delta)? onDelta,
    void Function(String delta)? onReasoning,
  }) async {
    final String apiKey = (AppConfig.dsApiKey ?? '').trim();
    if (apiKey.isEmpty) {
      throw DsApiException('未配置 DeepSeek API Key，请先在设置里填写');
    }

    final Map<String, dynamic> payload = <String, dynamic>{
      'model': model,
      'messages': <Map<String, dynamic>>[
        <String, dynamic>{'role': 'user', 'content': content},
      ],
      'stream': stream,
      'thinking': <String, String>{
        'type': thinking ? 'enabled' : 'disabled',
      },
    };

    final Uri uri = Uri.parse('$_baseUrl/chat/completions');
    final Map<String, String> headers = <String, String>{
      'Authorization': 'Bearer $apiKey',
      'Content-Type': 'application/json',
      'Accept': stream ? 'text/event-stream' : 'application/json',
    };

    return stream
        ? _chatStream(uri, headers, payload, onDelta, onReasoning)
        : _chatOnce(uri, headers, payload, onReasoning);
  }

  // ---------------------------------------------------------------- 判分

  /// 让 AI 给主观题（填空 / 解释）打分，返回 0-10 的整数。
  ///
  /// 提示词要求模型只输出一个整数；返回里若混了别的字符，
  /// 会提取第一个整数并夹到 0-10。
  static Future<int> scoreAnswer({
    required String question,
    required String standardAnswer,
    required String userAnswer,
    Uint8List? imageBytes,
  }) async {
    final String prompt = '''
你是医学考试阅卷助手。请判断学生作答与标准答案的契合程度，给出 0 到 10 的整数分数。

评分标准：
- 10：完全正确或语义等价
- 7-9：要点正确，表述略有出入
- 4-6：部分正确，只答到一部分要点
- 1-3：基本错误但沾边
- 0：完全错误或未作答

如果有附图，请结合图片内容判断学生作答是否正确。

题目：$question
标准答案：$standardAnswer
学生作答：$userAnswer

只输出一个整数（0-10），不要解释、不要标点。
''';

    // 有配图时用“文本 + 图片”的内容块数组，否则发纯文本
    final String raw = await _send(
      _withOptionalImage(prompt, imageBytes),
      stream: false,
      thinking: false,
    );
    return _parseScore(raw);
  }

  /// 让 AI 生成一道选择题的解析（为什么对、其它选项为什么错）。
  ///
  /// [options] 是已格式化的选项文本，一行一个，例如 `A. 上海`；
  /// [correctAnswer] 形如 `B. 北京`。有配图时一起发送。
  static Future<String> explainQuestion({
    required String question,
    required String options,
    required String correctAnswer,
    Uint8List? imageBytes,
  }) async {
    final String prompt = '''
你是医学课程的答疑老师。请针对下面这道选择题给出解析。

要求：
- 说明正确答案为什么正确；
- 简要说明其它选项为什么不对；
- 如果有附图，结合图片内容解释；
- 输出纯文本，不要 Markdown 标记、不要用星号或井号分点；
- 控制在 300 字以内。

题目：$question

选项：
$options

正确答案：$correctAnswer
''';

    final String text = await _send(
      _withOptionalImage(prompt, imageBytes),
      stream: false,
      thinking: false,
    );
    final String trimmed = text.trim();
    if (trimmed.isEmpty) {
      throw DsApiException('AI 未返回解析内容');
    }
    return trimmed;
  }

  /// 把提示词和可选图片组装成请求的 content。
  static Object _withOptionalImage(String prompt, Uint8List? imageBytes) {
    if (imageBytes == null || imageBytes.isEmpty) return prompt;

    return <Map<String, dynamic>>[
      <String, dynamic>{'type': 'text', 'text': prompt},
      <String, dynamic>{
        'type': 'image_url',
        'image_url': <String, String>{
          'url': 'data:${_imageMime(imageBytes)};base64,'
              '${base64Encode(imageBytes)}',
        },
      },
    ];
  }

  /// 按文件头判断图片 MIME；官方是按内容而非扩展名识别格式。
  static String _imageMime(Uint8List bytes) {
    bool startsWith(List<int> magic) {
      if (bytes.length < magic.length) return false;
      for (int i = 0; i < magic.length; i++) {
        if (bytes[i] != magic[i]) return false;
      }
      return true;
    }

    if (startsWith(<int>[0xFF, 0xD8, 0xFF])) return 'image/jpeg';
    if (startsWith(<int>[0x89, 0x50, 0x4E, 0x47])) return 'image/png';
    if (startsWith(<int>[0x47, 0x49, 0x46])) return 'image/gif';
    if (startsWith(<int>[0x52, 0x49, 0x46, 0x46])) return 'image/webp';
    return 'image/jpeg'; // 兜底
  }

  /// 从模型输出里提取 0-10 的整数分数。
  static int _parseScore(String raw) {
    final RegExpMatch? match = RegExp(r'\d{1,2}').firstMatch(raw);
    if (match == null) {
      throw DsApiException('AI 未返回有效分数：${raw.trim()}');
    }
    final int score = int.parse(match.group(0)!);
    return score.clamp(0, 10).toInt();
  }

  // ---------------------------------------------------------------- 非流式

  static Future<String> _chatOnce(
    Uri uri,
    Map<String, String> headers,
    Map<String, dynamic> payload,
    void Function(String delta)? onReasoning,
  ) async {
    final http.Client client = http.Client();
    try {
      final http.Response response = await client
          .post(uri, headers: headers, body: jsonEncode(payload))
          .timeout(_timeout);

      final String body =
          utf8.decode(response.bodyBytes, allowMalformed: true);

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
      throw DsApiException('请求超时（${_timeout.inSeconds} 秒），请检查网络后重试');
    } on http.ClientException catch (error) {
      throw DsApiException('网络请求失败：${error.message}');
    } catch (error) {
      throw DsApiException('请求失败：$error');
    } finally {
      client.close();
    }
  }

  // ---------------------------------------------------------------- 流式

  static Future<String> _chatStream(
    Uri uri,
    Map<String, String> headers,
    Map<String, dynamic> payload,
    void Function(String delta)? onDelta,
    void Function(String delta)? onReasoning,
  ) async {
    final http.Client client = http.Client();
    try {
      final http.Request request = http.Request('POST', uri)
        ..headers.addAll(headers)
        ..body = jsonEncode(payload);

      final http.StreamedResponse response =
          await client.send(request).timeout(_timeout);

      if (response.statusCode != 200) {
        final String body = await response.stream.bytesToString();
        throw _httpError(response.statusCode, body);
      }

      final StringBuffer buffer = StringBuffer();

      await for (final String line in response.stream
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
      throw DsApiException('请求超时（${_timeout.inSeconds} 秒），请检查网络后重试');
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

      final String? text =
          content is String && content.isNotEmpty ? content : null;
      final String? thought =
          reasoning is String && reasoning.isNotEmpty ? reasoning : null;

      if (text == null && thought == null) return null;
      return DsStreamDelta(content: text, reasoning: thought);
    } catch (_) {
      return null;
    }
  }

  // ---------------------------------------------------------------- 工具

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
        return DsApiException('请求参数有误（400）：$detail',
            statusCode: statusCode, body: body);
      case 401:
        return DsApiException('API Key 无效或已失效（401），请在设置里重新填写',
            statusCode: statusCode, body: body);
      case 402:
        return DsApiException('账户余额不足（402），请到 DeepSeek 平台充值',
            statusCode: statusCode, body: body);
      case 422:
        return DsApiException('请求格式错误（422）：$detail',
            statusCode: statusCode, body: body);
      case 429:
        return DsApiException('请求过于频繁（429），请稍后再试',
            statusCode: statusCode, body: body);
      case 500:
        return DsApiException('DeepSeek 服务异常（500），请稍后重试',
            statusCode: statusCode, body: body);
      case 503:
        return DsApiException('DeepSeek 服务繁忙（503），请稍后重试',
            statusCode: statusCode, body: body);
      default:
        return DsApiException('请求失败（$statusCode）：$detail',
            statusCode: statusCode, body: body);
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
