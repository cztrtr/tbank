import 'dart:io';

import 'package:flutter/material.dart';

import '../services/app_config.dart';
import '../services/mistake_books.dart';
import '../services/update_service.dart';
import 'plugins_page.dart';

/// 设置页。
///
/// 包含三项：
/// - 「DeepSeek 密钥」：输入并保存后经 base64 编码写入 config.json；
/// - 「应用更新」：填 cpolar 地址，下载 app-release.apk 并拉起系统安装器；
/// - 「重置错题本」：手动触发，删除所有已有错题本（连同配图）和删除记录。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final TextEditingController _keyController = TextEditingController(); // 密钥输入框
  final TextEditingController _updateUrlController =
      TextEditingController(); // 更新地址输入框
  bool _saving = false; // 是否正在保存，防止重复提交
  bool _resetting = false; // 是否正在重置错题本

  bool _downloading = false; // 是否正在下载更新包
  int _receivedBytes = 0; // 已下载字节数
  int? _totalBytes; // 总字节数；服务器未提供时为 null
  String? _updateMessage; // 更新结果 / 错误提示
  File? _downloadedFile; // 下载好的安装包（桌面端用来展示路径）

  @override
  void dispose() {
    _keyController.dispose();
    _updateUrlController.dispose();
    super.dispose();
  }

  /// 保存密钥：写入 config.json（AppConfig 内部做 base64 编码）。
  Future<void> _save() async {
    final String value = _keyController.text.trim();
    if (value.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请输入密钥后再保存')));
      return;
    }

    setState(() => _saving = true);
    try {
      await AppConfig.setDsApiKey(value);
      if (!mounted) return;

      _keyController.clear();
      FocusScope.of(context).unfocus();
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已保存')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('保存失败：$error')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 下载并（在 Android 上）拉起安装器。
  Future<void> _downloadUpdate() async {
    final String input = _updateUrlController.text.trim();
    if (input.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请先填写更新地址')));
      return;
    }

    FocusScope.of(context).unfocus();
    setState(() {
      _downloading = true;
      _updateMessage = null;
      _downloadedFile = null;
      _receivedBytes = 0;
      _totalBytes = null;
    });

    try {
      final File file = await UpdateService.download(
        input: input,
        onProgress: (int received, int? total) {
          if (!mounted) return;
          setState(() {
            _receivedBytes = received;
            _totalBytes = total;
          });
        },
      );
      if (!mounted) return;

      if (!UpdateService.supportsInstall) {
        setState(() {
          _downloadedFile = file;
          _updateMessage = '已下载到：${file.path}\n（桌面端请手动打开安装包）';
        });
        return;
      }

      final String status = await UpdateService.install(file);
      if (!mounted) return;
      setState(() {
        _downloadedFile = file;
        _updateMessage = switch (status) {
          'ok' => '下载完成，已打开系统安装界面',
          'permission' => '请允许「安装未知应用」后，再点一次「下载更新」',
          _ => '下载完成，但未能打开安装界面',
        };
      });
    } on UpdateException catch (error) {
      if (!mounted) return;
      setState(() => _updateMessage = error.message);
    } catch (error) {
      if (!mounted) return;
      setState(() => _updateMessage = '更新失败：$error');
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  /// 把字节数格式化成适合展示的大小。
  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  /// 重置错题本：二次确认后删除所有已有错题本（连同配图）并清空删除记录。
  ///
  /// 只影响 App 私有目录，原题库的题目和统计不受影响；
  /// 之后进入错题本页时，答错过的题会重新被收集。
  Future<void> _resetMistakeBooks() async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('重置错题本'),
        content: const Text(
          '将删除所有已有错题本（连同配图）和「已删除来源」记录。\n\n'
          '原题库的题目和统计不受影响，之后答错的题会重新被收集。\n\n'
          '此操作不可撤销。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('重置'),
          ),
        ],
      ),
    );

    if (!mounted || confirmed != true) return;

    setState(() => _resetting = true);
    try {
      final bool ok = await MistakeBooks.resetAll();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ok ? '错题本已重置' : '部分文件删除失败，请重试')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('重置错题本失败：$error')));
    } finally {
      if (mounted) setState(() => _resetting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    final TextTheme textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          // ---- 第一项：DeepSeek 密钥 ----
          Text(
            'DeepSeek 密钥',
            style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),

          // 配置状态；不回填原值，只提示是否已配置
          ValueListenableBuilder<String?>(
            valueListenable: AppConfig.dsApiKeyNotifier,
            builder: (BuildContext context, String? key, _) {
              final bool configured = (key ?? '').isNotEmpty;
              return Row(
                children: <Widget>[
                  Icon(
                    configured ? Icons.check_circle : Icons.circle_outlined,
                    size: 14,
                    color: configured
                        ? colorScheme.primary
                        : colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      configured ? '已配置，重新输入可覆盖' : '未配置',
                      style: TextStyle(
                        fontSize: 12,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 10),

          TextField(
            controller: _keyController,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _save(),
            decoration: InputDecoration(
              hintText: '粘贴 API Key',
              isDense: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
          const SizedBox(height: 12),

          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('保存'),
            ),
          ),

          const SizedBox(height: 28),
          const Divider(),
          const SizedBox(height: 16),

          // ---- 插件管理 ----
          Card(
            margin: EdgeInsets.zero,
            child: ListTile(
              leading: Icon(
                Icons.extension_outlined,
                color: colorScheme.primary,
              ),
              title: const Text('插件管理'),
              subtitle: const Text('导入 / 下载 / 卸载题库插件'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const PluginsPage()),
              ),
            ),
          ),

          const SizedBox(height: 28),
          const Divider(),
          const SizedBox(height: 16),

          // ---- 第二项：应用更新 ----
          Text(
            '应用更新',
            style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Text(
            '填写更新地址',
            style: TextStyle(
              fontSize: 12,
              height: 1.5,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _updateUrlController,
            keyboardType: TextInputType.url,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) {
              if (!_downloading) _downloadUpdate();
            },
            decoration: InputDecoration(
              hintText: '例如 https://xxxx.r9.cpolar.top',
              isDense: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _downloading ? null : _downloadUpdate,
              icon: _downloading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.system_update_alt, size: 20),
              label: Text(_downloading ? '正在下载…' : '下载更新'),
            ),
          ),
          if (_downloading) ...<Widget>[
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: (_totalBytes ?? 0) > 0
                  ? _receivedBytes / _totalBytes!
                  : null,
            ),
            const SizedBox(height: 4),
            Text(
              (_totalBytes ?? 0) > 0
                  ? '正在下载 ${_receivedBytes * 100 ~/ _totalBytes!}%'
                        '（${_formatBytes(_receivedBytes)} / '
                        '${_formatBytes(_totalBytes!)}）'
                  : '已下载 ${_formatBytes(_receivedBytes)}',
              style: TextStyle(
                fontSize: 12,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          if (_updateMessage != null) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              _updateMessage!,
              style: TextStyle(
                fontSize: 12,
                height: 1.5,
                color: _downloadedFile != null
                    ? colorScheme.primary
                    : colorScheme.error,
              ),
            ),
          ],
          if (_downloadedFile != null && !UpdateService.supportsInstall)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '文件：${_downloadedFile!.path}',
                style: TextStyle(
                  fontSize: 11,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),

          const SizedBox(height: 28),
          const Divider(),
          const SizedBox(height: 16),

          // ---- 第三项：重置错题本 ----
          Text(
            '错题本',
            style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Text(
            '删除所有已有错题本（连同配图）和「已删除来源」记录。'
            '原题库的题目和统计不受影响，之后答错的题会重新被收集。',
            style: TextStyle(
              fontSize: 12,
              height: 1.5,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _resetting ? null : _resetMistakeBooks,
              icon: _resetting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.delete_sweep_outlined, size: 18),
              label: Text(_resetting ? '正在重置…' : '重置错题本'),
              style: OutlinedButton.styleFrom(
                foregroundColor: colorScheme.error,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
