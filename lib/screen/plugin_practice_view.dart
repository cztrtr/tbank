import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_windows/webview_windows.dart';

import '../models/question_bank.dart';
import '../models/question_bank_file.dart';
import '../services/bank_io.dart';
import '../services/plugin_manager.dart';
import '../services/plugin_schema.dart';

/// 插件练习宿主：用 WebView 加载 `plugins/<id>/index.html`。
///
/// App 只提供题目数据、主题和结果回调；题面、作答区、结果区全部由插件渲染。
/// 统计、持久化和导航仍由 PracticePage 负责。
///
/// Android 用官方 webview_flutter，Windows 用 webview_windows（WebView2）。
class PluginPracticeView extends StatefulWidget {
  const PluginPracticeView({
    super.key,
    required this.pluginId,
    required this.question,
    required this.index,
    required this.total,
    required this.answered,
    required this.wasCorrect,
    required this.selected,
    required this.mistakeScore,
    required this.isMistakeDone,
    required this.aiEnabled,
    required this.correctAnswerText,
    required this.sourceDirectoryRef,
    required this.bankFile,
    required this.plugin,
    required this.onSubmit,
    required this.onNext,
    required this.onPrevious,
    required this.onRequestAiExplain,
    required this.onRequestAiScore,
    required this.onUpdatePluginData,
  });

  final String pluginId;
  final Question question;
  final int index;
  final int total;
  final bool answered;
  final bool wasCorrect;
  final Set<String> selected;
  final int? mistakeScore;
  final bool isMistakeDone;
  final bool aiEnabled;
  final String correctAnswerText;
  final String? sourceDirectoryRef;
  final QuestionBankFile? bankFile;
  final PluginManifest? plugin;

  final void Function(bool correct, Set<String> selected) onSubmit;
  final VoidCallback onNext;
  final VoidCallback onPrevious;
  final Future<String> Function(String answer) onRequestAiExplain;
  final Future<int> Function(String answer, List<Uint8List> images)
  onRequestAiScore;
  final Future<void> Function(Map<String, dynamic> pluginData)
  onUpdatePluginData;

  @override
  State<PluginPracticeView> createState() => _PluginPracticeViewState();
}

class _PluginPracticeViewState extends State<PluginPracticeView> {
  WebViewController? _androidController;
  WebviewController? _windowsController;
  StreamSubscription<dynamic>? _windowsMessage;
  StreamSubscription<LoadingState>? _windowsLoading;

  String? _error;
  bool _pageReady = false;

  @override
  void initState() {
    super.initState();
    _resolveEntry();
  }

  @override
  void didUpdateWidget(covariant PluginPracticeView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pluginId != widget.pluginId) {
      _pageReady = false;
      _resolveEntry();
      return;
    }
    if (_pageReady) _pushContext();
  }

  @override
  void dispose() {
    _windowsMessage?.cancel();
    _windowsLoading?.cancel();
    _windowsController?.dispose();
    super.dispose();
  }

  Future<void> _resolveEntry() async {
    final String? path = await PluginManager.entryFile(widget.pluginId);
    if (!mounted) return;
    if (path == null) {
      setState(() {
        _error = '插件「${widget.pluginId}」缺少 index.html';
      });
      return;
    }

    setState(() {
      _error = null;
    });

    if (Platform.isWindows) {
      await _initWindows(path);
    } else {
      await _initAndroid(path);
    }
  }

  Future<void> _initAndroid(String entryPath) async {
    try {
      final WebViewController controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..addJavaScriptChannel(
          'TBankChannel',
          onMessageReceived: (JavaScriptMessage message) {
            _handleMessage(message.message);
          },
        )
        ..setNavigationDelegate(
          NavigationDelegate(
            onPageFinished: (String url) {
              _pageReady = true;
              _pushContext();
            },
            onWebResourceError: (WebResourceError error) {
              if (error.isForMainFrame == true) {
                _setError('插件页面加载失败：${error.description}');
              }
            },
          ),
        );
      await controller.loadFile(entryPath);
      if (!mounted) return;
      setState(() => _androidController = controller);
    } catch (error) {
      _setError('插件页面初始化失败：$error');
    }
  }

  Future<void> _initWindows(String entryPath) async {
    try {
      final WebviewController controller = WebviewController();
      await controller.initialize();
      await controller.setBackgroundColor(Colors.transparent);

      _windowsMessage = controller.webMessage.listen((dynamic message) {
        if (message is String) {
          _handleMessage(message);
        } else if (message is Map) {
          _handleMessage(jsonEncode(message));
        }
      });
      _windowsLoading = controller.loadingState.listen((LoadingState state) {
        if (state == LoadingState.none) {
          _pageReady = true;
          _pushContext();
        }
      });

      await controller.loadUrl(Uri.file(entryPath).toString());
      if (!mounted) return;
      setState(() => _windowsController = controller);
    } catch (error) {
      _setError('插件页面初始化失败：$error');
    }
  }

  void _setError(String message) {
    if (!mounted) return;
    setState(() {
      _error = message;
      _pageReady = false;
    });
  }

  Future<void> _handleMessage(String raw) async {
    final dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return;
    }
    if (decoded is! Map) return;

    final String? id = decoded['id']?.toString();
    final String name = decoded['name']?.toString() ?? '';
    final Map<String, dynamic> args = decoded['args'] is Map
        ? Map<String, dynamic>.from(decoded['args'] as Map)
        : <String, dynamic>{};

    try {
      dynamic result = true;
      switch (name) {
        case 'tbankSubmit':
          final Set<String> selected = args['selected'] is List
              ? (args['selected'] as List)
                    .map((dynamic item) => item.toString())
                    .toSet()
              : <String>{};
          widget.onSubmit(args['correct'] == true, selected);
          break;
        case 'tbankNext':
          widget.onNext();
          break;
        case 'tbankPrevious':
          widget.onPrevious();
          break;
        case 'tbankAiExplain':
          result = await widget.onRequestAiExplain(
            args['answer']?.toString() ?? '',
          );
          break;
        case 'tbankAiScore':
          final List<Uint8List> images = args['images'] is List
              ? (args['images'] as List)
                    .map((dynamic item) => _decodeDataUrl(item.toString()))
                    .whereType<Uint8List>()
                    .toList()
              : <Uint8List>[];
          result = await widget.onRequestAiScore(
            args['answer']?.toString() ?? '',
            images,
          );
          break;
        case 'tbankReadBank':
          final QuestionBankFile? bankFile = widget.bankFile;
          if (bankFile == null) throw StateError('当前没有题库文件');
          result = await BankIo.readText(bankFile.uri);
          break;
        case 'tbankUpdatePluginData':
          final dynamic rawData = args['pluginData'];
          if (rawData is! Map) {
            throw const PluginException('pluginData 必须是对象');
          }
          final Map<String, dynamic> data = Map<String, dynamic>.from(rawData);
          final Map<String, dynamic>? schema = widget.plugin?.schemaForType(
            widget.question.typeId,
          );
          if (schema != null) {
            final String? error = PluginSchemaValidator.validate(schema, data);
            if (error != null) throw PluginException(error);
          }
          await widget.onUpdatePluginData(data);
          break;
        case 'tbankReadImage':
          final String? directory = widget.sourceDirectoryRef;
          final String imageName = args['name']?.toString() ?? '';
          if (directory == null || imageName.isEmpty) {
            throw StateError('没有可读取的图片');
          }
          final Uint8List? bytes = await BankIo.readSiblingBytes(
            directory,
            imageName,
          );
          if (bytes == null || bytes.isEmpty) {
            throw StateError('图片不存在：$imageName');
          }
          result = <String, dynamic>{'dataUrl': _dataUrl(bytes)};
          break;
        case 'tbankFetch':
          result = await _fetch(args);
          break;
        case 'tbankClipboardRead':
          final ClipboardData? data = await Clipboard.getData(
            Clipboard.kTextPlain,
          );
          result = data?.text ?? '';
          break;
        case 'tbankClipboardWrite':
          await Clipboard.setData(
            ClipboardData(text: args['text']?.toString() ?? ''),
          );
          break;
        case 'tbankPickImage':
          result = await _pickImage(args);
          break;
        case 'tbankToast':
          final String message = args['message']?.toString() ?? '';
          if (message.isNotEmpty && mounted) {
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text(message)));
          }
          break;
        default:
          result = null;
      }
      await _respond(id, result);
    } catch (error) {
      await _reject(id, error.toString());
    }
  }

  Future<Map<String, dynamic>> _fetch(Map<String, dynamic> args) async {
    final String url = args['url']?.toString() ?? '';
    final Uri? uri = Uri.tryParse(url);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return <String, dynamic>{'error': '仅支持 http/https 地址'};
    }

    final String method = (args['method']?.toString() ?? 'GET').toUpperCase();
    final Map<String, String> headers = <String, String>{};
    if (args['headers'] is Map) {
      (args['headers'] as Map).forEach((dynamic key, dynamic value) {
        headers[key.toString()] = value.toString();
      });
    }
    final String? body = args['body']?.toString();

    final http.Client client = http.Client();
    try {
      final http.Response response = method == 'POST'
          ? await client
                .post(uri, headers: headers, body: body)
                .timeout(const Duration(seconds: 30))
          : await client
                .get(uri, headers: headers)
                .timeout(const Duration(seconds: 30));

      if (response.bodyBytes.length > 1024 * 1024) {
        return <String, dynamic>{'error': '响应超过 1 MB，已拒绝'};
      }
      return <String, dynamic>{
        'status': response.statusCode,
        'body': utf8.decode(response.bodyBytes, allowMalformed: true),
      };
    } catch (error) {
      return <String, dynamic>{'error': '网络请求失败：$error'};
    } finally {
      client.close();
    }
  }

  Future<Map<String, dynamic>> _pickImage(Map<String, dynamic> args) async {
    try {
      final ImageSource source = args['source'] == 'camera'
          ? ImageSource.camera
          : ImageSource.gallery;
      final XFile? picked = await ImagePicker().pickImage(
        source: source,
        maxWidth: 1600,
        imageQuality: 85,
      );
      if (picked == null) return <String, dynamic>{'cancelled': true};
      final Uint8List bytes = await picked.readAsBytes();
      if (bytes.length > 5 * 1024 * 1024) {
        return <String, dynamic>{'error': '图片超过 5 MB'};
      }
      return <String, dynamic>{'dataUrl': _dataUrl(bytes)};
    } catch (error) {
      return <String, dynamic>{'error': '选择图片失败：$error'};
    }
  }

  String _dataUrl(Uint8List bytes) =>
      'data:${_imageMime(bytes)};base64,${base64Encode(bytes)}';

  Uint8List? _decodeDataUrl(String value) {
    if (!value.startsWith('data:')) return null;
    final int comma = value.indexOf(',');
    if (comma < 0) return null;
    try {
      return base64Decode(value.substring(comma + 1));
    } catch (_) {
      return null;
    }
  }

  Future<void> _respond(String? id, dynamic result) async {
    if (id == null) return;
    final String json = jsonEncode(result)
        .replaceAll('\u2028', '\\u2028')
        .replaceAll('\u2029', '\\u2029');
    await _eval('window.__tbankResolve(${jsonEncode(id)}, $json);');
  }

  Future<void> _reject(String? id, String message) async {
    if (id == null) return;
    final String json = jsonEncode(message)
        .replaceAll('\u2028', '\\u2028')
        .replaceAll('\u2029', '\\u2029');
    await _eval('window.__tbankReject(${jsonEncode(id)}, $json);');
  }

  Future<void> _eval(String script) async {
    try {
      if (Platform.isWindows) {
        await _windowsController?.executeScript(script);
      } else {
        await _androidController?.runJavaScript(script);
      }
    } catch (error) {
      debugPrint('执行插件脚本失败：$error');
    }
  }

  Future<void> _pushContext() async {
    if (!_pageReady) return;
    final Map<String, dynamic> context = await _contextWithImage();
    final String json = jsonEncode(context)
        .replaceAll('\u2028', '\\u2028')
        .replaceAll('\u2029', '\\u2029');
    await _eval('window.__tbankReceive($json);');
  }

  Future<Map<String, dynamic>> _contextWithImage() async {
    final Map<String, dynamic> context = _context();
    final Question question = widget.question;
    final String? directory = widget.sourceDirectoryRef;
    if (!question.hasImage || directory == null) return context;

    try {
      final Uint8List? bytes = await BankIo.readSiblingBytes(
        directory,
        question.image,
      );
      if (bytes == null || bytes.isEmpty) return context;
      final String mime = _imageMime(bytes);
      final String data = 'data:$mime;base64,${base64Encode(bytes)}';
      final Map<String, dynamic> questionMap =
          context['question'] as Map<String, dynamic>;
      questionMap['imageDataUrl'] = data;
    } catch (error) {
      debugPrint('读取插件题目配图失败：$error');
    }
    return context;
  }

  String _imageMime(Uint8List bytes) {
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return 'image/png';
    }
    if (bytes.length >= 3 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xD8 &&
        bytes[2] == 0xFF) {
      return 'image/jpeg';
    }
    if (bytes.length >= 6 &&
        bytes[0] == 0x47 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46) {
      return 'image/gif';
    }
    return 'image/webp';
  }

  Map<String, dynamic> _context() {
    final Question question = widget.question;
    final ColorScheme colors = Theme.of(context).colorScheme;

    return <String, dynamic>{
      'plugin': widget.pluginId,
      'index': widget.index,
      'total': widget.total,
      'answered': widget.answered,
      'wasCorrect': widget.wasCorrect,
      'selected': widget.selected.toList(),
      'correctAnswerText': widget.correctAnswerText,
      'mistakeScore': widget.mistakeScore,
      'isMistakeDone': widget.isMistakeDone,
      'aiEnabled': widget.aiEnabled,
      'question': <String, dynamic>{
        'id': question.id,
        'type': question.typeId,
        'question': question.question,
        'options': question.options
            .map(
              (QuestionOption option) => <String, String>{
                'key': option.key,
                'text': option.text,
              },
            )
            .toList(),
        'correctAnswers': question.correctAnswers,
        'analysis': question.analysis,
        'image': question.image,
        'pluginData': ?question.pluginData,
        'stats': <String, int>{
          'attemptCount': question.stats.attemptCount,
          'wrongCount': question.stats.wrongCount,
        },
      },
      'theme': <String, String>{
        'background': _hex(colors.surface),
        'surface': _hex(colors.surfaceContainerLow),
        'text': _hex(colors.onSurface),
        'muted': _hex(colors.onSurfaceVariant),
        'line': _hex(colors.outlineVariant),
        'primary': _hex(colors.primary),
        'primarySoft': _hex(colors.primaryContainer),
        'ok': _hex(colors.primary),
        'okSoft': _hex(colors.primaryContainer),
        'bad': _hex(colors.error),
        'badSoft': _hex(colors.errorContainer),
      },
    };
  }

  String _hex(Color color) {
    final int value = color.toARGB32() & 0xFFFFFF;
    return '#${value.toRadixString(16).padLeft(6, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error!, textAlign: TextAlign.center),
        ),
      );
    }

    if (Platform.isWindows) {
      final WebviewController? controller = _windowsController;
      if (controller == null) {
        return const Center(child: CircularProgressIndicator());
      }
      return Webview(controller);
    }

    final WebViewController? controller = _androidController;
    if (controller == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return WebViewWidget(controller: controller);
  }
}
