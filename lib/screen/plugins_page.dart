import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../services/plugin_manager.dart';
import 'plugin_config_page.dart';

/// 插件管理页：列出插件、导入本地 zip、从网络下载 zip、卸载非内置插件。
class PluginsPage extends StatefulWidget {
  const PluginsPage({super.key});

  @override
  State<PluginsPage> createState() => _PluginsPageState();
}

class _PluginsPageState extends State<PluginsPage> {
  bool _loading = true;
  bool _busy = false;
  String? _error;
  List<PluginManifest> _plugins = <PluginManifest>[];
  String _directory = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final Directory dir = await PluginManager.directory();
      final List<PluginManifest> plugins = await PluginManager.list();
      if (!mounted) return;
      setState(() {
        _directory = dir.path;
        _plugins = plugins;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '读取插件失败：$error';
        _loading = false;
      });
    }
  }

  Future<void> _importZip() async {
    if (_busy) return;
    try {
      final List<PlatformFile> picked = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: <String>['zip'],
      );
      if (picked.isEmpty) return;
      final String? path = picked.first.path;
      if (path == null) return;
      await _install(() => PluginManager.importZip(File(path)));
    } catch (error) {
      _toast('导入失败：$error');
    }
  }

  Future<void> _downloadZip() async {
    if (_busy) return;
    final TextEditingController controller = TextEditingController();
    final String? url = await showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('从网络安装插件'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            hintText: 'https://example.com/plugin.zip',
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('下载并安装'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (url == null || url.isEmpty) return;
    await _install(() => PluginManager.download(url));
  }

  Future<void> _install(Future<PluginManifest> Function() action) async {
    setState(() => _busy = true);
    try {
      final PluginManifest plugin = await action();
      if (!mounted) return;
      _toast('已安装 ${plugin.name} v${plugin.version}');
      await _load();
    } on PluginException catch (error) {
      if (mounted) _toast(error.message);
    } catch (error) {
      if (mounted) _toast('安装失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _uninstall(PluginManifest plugin) async {
    if (plugin.builtin || _busy) return;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('卸载插件'),
        content: Text(
          '确定卸载「${plugin.name}」吗？\n\n'
          '使用这个插件的题库和错题本不会被删除，只是暂时打不开。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('卸载'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    try {
      await PluginManager.uninstall(plugin.id);
      if (!mounted) return;
      _toast('已卸载 ${plugin.name}');
      await _load();
    } on PluginException catch (error) {
      if (mounted) _toast(error.message);
    } catch (error) {
      if (mounted) _toast('卸载失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  void _openConfig(PluginManifest plugin) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => PluginConfigPage(plugin: plugin)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('插件管理'),
        actions: <Widget>[
          IconButton(
            tooltip: '导入本地 zip',
            onPressed: _busy ? null : _importZip,
            icon: const Icon(Icons.folder_open),
          ),
          IconButton(
            tooltip: '从网络下载',
            onPressed: _busy ? null : _downloadZip,
            icon: const Icon(Icons.cloud_download_outlined),
          ),
        ],
      ),
      body: _buildBody(colorScheme),
    );
  }

  Widget _buildBody(ColorScheme colorScheme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton(onPressed: _load, child: const Text('重试')),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: <Widget>[
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '插件目录',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 4),
                SelectableText(
                  _directory,
                  style: TextStyle(
                    fontSize: 12,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '右上角可以导入本地 .zip，或从网络下载安装；内置插件不可卸载。',
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.5,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (_busy) ...<Widget>[
            const LinearProgressIndicator(minHeight: 2),
            const SizedBox(height: 8),
          ],
          for (final PluginManifest plugin in _plugins)
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                leading: Icon(
                  plugin.builtin
                      ? Icons.verified_outlined
                      : Icons.extension_outlined,
                  color: plugin.builtin
                      ? colorScheme.primary
                      : colorScheme.onSurfaceVariant,
                ),
                title: Text(plugin.name),
                subtitle: Text(
                  'v${plugin.version} · API ${plugin.apiVersion}\n'
                  '处理题型：${plugin.types.join('、')}'
                  '${plugin.description.isEmpty ? '' : '\n${plugin.description}'}',
                  style: const TextStyle(fontSize: 12, height: 1.4),
                ),
                isThreeLine: true,
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    if (plugin.builtin)
                      Chip(
                        label: const Text('内置'),
                        labelStyle: const TextStyle(fontSize: 11),
                        visualDensity: VisualDensity.compact,
                        side: BorderSide(color: colorScheme.outlineVariant),
                      ),
                    IconButton(
                      tooltip: '插件配置',
                      visualDensity: VisualDensity.compact,
                      onPressed: _busy ? null : () => _openConfig(plugin),
                      icon: const Icon(Icons.settings_outlined),
                    ),
                    if (!plugin.builtin)
                      IconButton(
                        tooltip: '卸载',
                        onPressed: _busy ? null : () => _uninstall(plugin),
                        icon: Icon(
                          Icons.delete_outline,
                          color: colorScheme.error,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          if (_plugins.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                '还没有安装插件',
                textAlign: TextAlign.center,
                style: TextStyle(color: colorScheme.onSurfaceVariant),
              ),
            ),
        ],
      ),
    );
  }
}
