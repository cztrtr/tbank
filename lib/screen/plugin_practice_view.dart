import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_windows/webview_windows.dart';

import '../models/question_bank.dart';
import '../models/question_bank_file.dart';
import '../services/app_config.dart';
import '../services/bank_io.dart';
import '../services/pen_gesture.dart';
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
    this.active = true,
    required this.onSubmit,
    required this.onNext,
    required this.onPrevious,
    required this.onRequestAiExplain,
    required this.onRequestAiScore,
    required this.onRequestAiComplete,
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

  /// 当前练习 tab 是否可见；切到其它 tab 时暂停插件计时器/渲染。
  final bool active;

  final void Function(bool correct, Set<String> selected) onSubmit;
  final VoidCallback onNext;
  final VoidCallback onPrevious;
  final Future<String> Function(String answer) onRequestAiExplain;
  final Future<int> Function(String answer, List<Uint8List> images)
  onRequestAiScore;
  final Future<String> Function(String prompt, List<Uint8List> images)
  onRequestAiComplete;
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
  StreamSubscription<int>? _penGestureSub;

  /// 插件根目录的绝对路径，用于限制 WebView 只能加载本地插件页面。
  String? _pluginRoot;
  String? _windowsEntryUrl;
  StreamSubscription<String>? _windowsUrlSub;

  /// 上一次推送的 context 签名；父页面 rebuild 但题目/状态没变时跳过。
  String? _lastPushedSignature;

  /// 切题/连续 setState 时只让最后一次推送生效。
  int _pushVersion = 0;

  /// 题目配图 data URL 缓存。题目 id + 文件名不变时复用，避免重复读盘/base64。
  String? _cachedImageKey;
  String? _cachedImageDataUrl;

  @override
  void initState() {
    super.initState();
    // 小米焦点笔 Pro 的 195（双击）等系统手势，转发给当前插件页面。
    // 页面没加载好时直接丢弃，避免寄存器里堆事件。
    _penGestureSub = PenGesture.events.listen((int code) {
      if (!_pageReady) return;
      _eval('window.__tbankPenGesture($code)');
    });
    _resolveEntry();
  }

  @override
  void didUpdateWidget(covariant PluginPracticeView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pluginId != widget.pluginId) {
      _pageReady = false;
      _lastPushedSignature = null;
      _resolveEntry();
      return;
    }
    if (oldWidget.active != widget.active) {
      unawaited(_applyActiveState());
    }
    // 父页面每次 setState 都会走到这里；_pushContext 内部会先比对签名，
    // 只有题目/作答/主题等真的变化才读图和执行 JS。
    if (_pageReady) unawaited(_pushContext());
  }

  /// 通知插件暂停/恢复（计时器、手写动画等），并尽量挂起 WebView2。
  Future<void> _applyActiveState() async {
    if (!_pageReady) return;
    if (Platform.isWindows) {
      try {
        if (widget.active) {
          await _windowsController?.resume();
        } else {
          await _windowsController?.suspend();
        }
      } catch (error) {
        debugPrint('切换插件 WebView 状态失败：$error');
      }
    }
    await _eval(
      widget.active
          ? 'window.__tbankResume && window.__tbankResume();'
          : 'window.__tbankPause && window.__tbankPause();',
    );
  }

  @override
  void dispose() {
    _penGestureSub?.cancel();
    _windowsMessage?.cancel();
    _windowsLoading?.cancel();
    _windowsUrlSub?.cancel();
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

    // 记住插件目录：Android 的 NavigationDelegate 只允许 file:// 且位于
    // 这个目录下的页面，防止插件跳转到远程站点后继续调用 TBankChannel。
    _pluginRoot = p.dirname(path);
    _windowsEntryUrl = Uri.file(path).toString();
    _lastPushedSignature = null;
    _cachedImageKey = null;
    _cachedImageDataUrl = null;

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
            onNavigationRequest: (NavigationRequest request) {
              // 只允许插件目录内的本地页面；外部导航一律阻止，避免远程
              // 页面继承 TBankChannel 后读取题库/剪贴板/发网络请求。
              if (_isAllowedNavigation(request.url)) {
                return NavigationDecision.navigate;
              }
              debugPrint('已阻止插件导航：${request.url}');
              return NavigationDecision.prevent;
            },
            onPageFinished: (String url) {
              _pageReady = true;
              unawaited(_pushContext());
              unawaited(_applyActiveState());
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
      // WebView2 0.4.0 没有导航拦截 API：至少拒绝弹窗，并用 URL 流做看门狗。
      await controller.setPopupWindowPolicy(WebviewPopupWindowPolicy.deny);

      _windowsUrlSub = controller.url.listen((String url) {
        if (!_isAllowedNavigation(url)) {
          debugPrint('已阻止插件导航：$url');
          unawaited(controller.stop());
          final String? entry = _windowsEntryUrl;
          if (entry != null) unawaited(controller.loadUrl(entry));
        }
      });

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
          unawaited(_pushContext());
          unawaited(_applyActiveState());
        }
      });

      await controller.loadUrl(Uri.file(entryPath).toString());
      if (!mounted) return;
      setState(() => _windowsController = controller);

      // WebView2 对本地 file:// 页面的 loadingState 事件偶尔早于页面脚本完成，
      // 再补一次延迟推送；真正的等待逻辑在 _pushContext 的 JS 重试里。
      Timer(const Duration(milliseconds: 800), () {
        if (!mounted || _windowsController != controller) return;
        _pageReady = true;
        unawaited(_pushContext());
        unawaited(_applyActiveState());
      });
    } catch (error) {
      _setError('插件页面初始化失败：$error');
    }
  }

  /// 判断一个 URL 是否允许在插件 WebView 里加载。
  bool _isAllowedNavigation(String raw) {
    final Uri? uri = Uri.tryParse(raw);
    if (uri == null) return false;
    if (uri.scheme == 'about' || uri.scheme == 'data' || uri.scheme == 'blob') {
      return true;
    }
    if (uri.scheme != 'file') return false;
    final String? root = _pluginRoot;
    if (root == null) return false;
    try {
      final String path = p.absolute(uri.toFilePath());
      final String base = p.absolute(root);
      return path == base || p.isWithin(base, path);
    } catch (_) {
      return false;
    }
  }

  void _setError(String message) {
    if (!mounted) return;
    setState(() {
      _error = message;
      _pageReady = false;
    });
  }

  /// v2 插件必须显式声明高风险能力；v1 旧插件保持兼容。
  void _requireCapability(String capability) {
    final PluginManifest? plugin = widget.plugin;
    if (plugin != null && !plugin.allows(capability)) {
      throw PluginException('插件未声明 $capability 能力，已拒绝');
    }
  }

  Future<void> _handleMessage(String raw) async {
    // 单条桥消息上限 2 MB；防止插件塞入超大字符串拖垮主 isolate。
    if (raw.length > 2 * 1024 * 1024) {
      debugPrint('插件消息过大，已丢弃');
      return;
    }
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
          _requireCapability('ai');
          result = await widget.onRequestAiExplain(
            args['answer']?.toString() ?? '',
          );
          break;
        case 'tbankAiScore':
          _requireCapability('ai');
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
        case 'tbankAiComplete':
          _requireCapability('ai');
          final List<Uint8List> completeImages = args['images'] is List
              ? (args['images'] as List)
                    .map((dynamic item) => _decodeDataUrl(item.toString()))
                    .whereType<Uint8List>()
                    .take(6)
                    .toList()
              : <Uint8List>[];
          result = await widget.onRequestAiComplete(
            args['prompt']?.toString() ?? '',
            completeImages,
          );
          break;
        case 'tbankConfigGet':
          _requireCapability('config');
          result = await PluginManager.readConfig(widget.pluginId);
          break;
        case 'tbankSetPenSettings':
          _requireCapability('pen');
          // 手写板参数回传：插件改完笔宽 / 橡皮模式 / 网格后存到 App 配置里，
          // 换题库、换题组都能沿用同一套手感。
          await AppConfig.savePenSettings(
            width: (args['width'] as num?)?.toDouble(),
            eraserMode: args['eraserMode'] as String?,
            grid: args['grid'] as bool?,
          );
          result = true;
          break;
        case 'tbankReadBank':
          _requireCapability('readBank');
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
          _requireCapability('fetch');
          result = await _fetch(args);
          break;
        case 'tbankClipboardRead':
          _requireCapability('clipboard');
          final ClipboardData? data = await Clipboard.getData(
            Clipboard.kTextPlain,
          );
          result = data?.text ?? '';
          break;
        case 'tbankClipboardWrite':
          _requireCapability('clipboard');
          await Clipboard.setData(
            ClipboardData(text: args['text']?.toString() ?? ''),
          );
          break;
        case 'tbankPickImage':
          _requireCapability('pickImage');
          result = await _pickImage(args);
          break;
        case 'tbankToast':
          _requireCapability('toast');
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
    if (uri == null || uri.scheme != 'https') {
      return <String, dynamic>{'error': '仅支持 https 地址'};
    }
    // v2 插件必须声明 networkHosts；空列表等于禁止联网。
    final PluginManifest? plugin = widget.plugin;
    if (plugin != null && plugin.apiVersion >= 2) {
      final List<String> hosts = plugin.networkHosts;
      final String host = uri.host.toLowerCase();
      final bool allowed = hosts.any((String rule) {
        final String value = rule.toLowerCase();
        if (value.startsWith('.')) return host.endsWith(value);
        return host == value;
      });
      if (!allowed) {
        return <String, dynamic>{'error': '插件未获准访问该域名'};
      }
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

    final int version = ++_pushVersion;
    // 先比较不含图片的 context；父页面 rebuild 但题目状态没变时直接跳过，
    // 避免重复读盘、base64 编码和 JS 执行。
    final Map<String, dynamic> context = _context();
    final String signature = jsonEncode(context);
    if (signature == _lastPushedSignature) return;

    final Map<String, dynamic> fullContext = await _contextWithImage(context);
    // 等待读图期间又切了题/改了状态：丢弃这次过期推送。
    if (!mounted || version != _pushVersion) return;

    final String json = jsonEncode(fullContext)
        .replaceAll('\u2028', '\\u2028')
        .replaceAll('\u2029', '\\u2029');
    // WebView2 的 loadingState.none 可能早于插件脚本定义 __tbankReceive；
    // 宿主只推一次会一直停在插件自己的 loading 页，所以等函数就绪后再推。
    await _eval('''
(function () {
  var payload = $json;
  var tries = 0;
  function apply() {
    if (typeof window.__tbankReceive !== 'function') return false;
    try {
      window.__tbankReceive(payload);
      return true;
    } catch (error) {
      console.error('tbankReceive failed', error);
      return false;
    }
  }
  if (apply()) return;
  var timer = setInterval(function () {
    if (apply() || ++tries > 100) clearInterval(timer);
  }, 50);
})();
''');
    _lastPushedSignature = signature;
  }

  Future<Map<String, dynamic>> _contextWithImage(
    Map<String, dynamic> context,
  ) async {
    final Question question = widget.question;
    final String? directory = widget.sourceDirectoryRef;
    if (!question.hasImage || directory == null) return context;

    final String cacheKey = '${question.id}|${question.image}|$directory';
    String? data = _cachedImageDataUrl;
    if (_cachedImageKey != cacheKey || data == null) {
      try {
        final Uint8List? bytes = await BankIo.readSiblingBytes(
          directory,
          question.image,
        );
        if (bytes == null || bytes.isEmpty) return context;
        final String mime = _imageMime(bytes);
        data = 'data:$mime;base64,${base64Encode(bytes)}';
        _cachedImageKey = cacheKey;
        _cachedImageDataUrl = data;
      } catch (error) {
        debugPrint('读取插件题目配图失败：$error');
        return context;
      }
    }

    final Map<String, dynamic> questionMap =
        context['question'] as Map<String, dynamic>;
    questionMap['imageDataUrl'] = data;
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
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return 'image/webp';
    }
    // 未知格式按 jpeg 交给 WebView 兜底；之前统一返回 webp 会让 png/jpeg 被误标。
    return 'image/jpeg';
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
      // 手写笔相关设置：插件读 settings.penDoubleTapMs 调整双击判定窗口，
      // settings.penOnlyInput 控制手写板是否屏蔽手指落笔；
      // penWidth / eraserMode / grid 是手写板上次用的参数，换题库也沿用。
      'settings': <String, dynamic>{
        'penDoubleTapMs': AppConfig.penDoubleTapMs,
        'penOnlyInput': AppConfig.penOnlyInput,
        'penWidth': AppConfig.penScratchWidth,
        'eraserMode': AppConfig.penEraserMode,
        'grid': AppConfig.penGrid,
      },
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
