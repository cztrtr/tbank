import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_windows/webview_windows.dart';

import '../services/plugin_manager.dart';

/// 插件配置页：加载插件根目录下固定的 `config.html`。
class PluginConfigPage extends StatelessWidget {
  const PluginConfigPage({super.key, required this.plugin});

  final PluginManifest plugin;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('${plugin.name} · 配置')),
      body: PluginConfigView(plugin: plugin),
    );
  }
}

/// 配置页的 WebView 宿主。
///
/// 配置数据单独存放在 `plugins/<id>/config.json`，插件页面通过
/// `tbankConfigGet` / `tbankConfigSet` 读写，不能访问其它插件或题库文件。
class PluginConfigView extends StatefulWidget {
  const PluginConfigView({super.key, required this.plugin});

  final PluginManifest plugin;

  @override
  State<PluginConfigView> createState() => _PluginConfigViewState();
}

class _PluginConfigViewState extends State<PluginConfigView> {
  WebViewController? _androidController;
  WebviewController? _windowsController;
  StreamSubscription<dynamic>? _windowsMessage;
  StreamSubscription<LoadingState>? _windowsLoading;

  Map<String, dynamic> _config = <String, dynamic>{};
  String? _error;
  bool _pageReady = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _windowsMessage?.cancel();
    _windowsLoading?.cancel();
    _windowsController?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final String? entry = await PluginManager.configPageFile(widget.plugin.id);
    if (!mounted) return;
    if (entry == null) {
      setState(() {
        _error =
            '这个插件没有提供 ${PluginManager.configPageName} 配置页。\n'
            '插件作者可以把配置页放在插件根目录下。';
      });
      return;
    }

    try {
      _config = await PluginManager.readConfig(widget.plugin.id);
    } catch (error) {
      debugPrint('读取插件配置失败：$error');
      _config = <String, dynamic>{};
    }

    if (!mounted) return;
    setState(() => _error = null);

    if (Platform.isWindows) {
      await _initWindows(entry);
    } else {
      await _initAndroid(entry);
    }
  }

  Future<void> _initAndroid(String entry) async {
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
                _setError('配置页加载失败：${error.description}');
              }
            },
          ),
        );
      await controller.loadFile(entry);
      if (!mounted) return;
      setState(() => _androidController = controller);
    } catch (error) {
      _setError('配置页初始化失败：$error');
    }
  }

  Future<void> _initWindows(String entry) async {
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

      await controller.loadUrl(Uri.file(entry).toString());
      if (!mounted) return;
      setState(() => _windowsController = controller);
    } catch (error) {
      _setError('配置页初始化失败：$error');
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
        case 'tbankConfigGet':
          result = _config;
          break;
        case 'tbankConfigSet':
          final dynamic rawConfig = args['config'];
          if (rawConfig is! Map) {
            throw const PluginException('config 必须是对象');
          }
          final Map<String, dynamic> next = Map<String, dynamic>.from(
            rawConfig,
          );
          await PluginManager.writeConfig(widget.plugin.id, next);
          _config = next;
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
      debugPrint('执行配置页脚本失败：$error');
    }
  }

  Future<void> _pushContext() async {
    if (!_pageReady) return;
    final Map<String, dynamic> data = <String, dynamic>{
      'plugin': widget.plugin.toJson(),
      'config': _config,
    };
    final String json = jsonEncode(data)
        .replaceAll('\u2028', '\\u2028')
        .replaceAll('\u2029', '\\u2029');
    await _eval('window.__tbankConfigReceive($json);');
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
