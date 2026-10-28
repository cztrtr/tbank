import 'package:flutter/material.dart';

import '../services/app_config.dart';

/// 设置页。
///
/// 目前只有「DeepSeek 密钥」一项：输入并保存后经 base64 编码写入 config.json。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final TextEditingController _keyController = TextEditingController(); // 密钥输入框
  bool _saving = false; // 是否正在保存，防止重复提交

  @override
  void dispose() {
    _keyController.dispose();
    super.dispose();
  }

  /// 保存密钥：写入 config.json（AppConfig 内部做 base64 编码）。
  Future<void> _save() async {
    final String value = _keyController.text.trim();
    if (value.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入密钥后再保存')),
      );
      return;
    }

    setState(() => _saving = true);
    try {
      await AppConfig.setDsApiKey(value);
      if (!mounted) return;

      _keyController.clear();
      FocusScope.of(context).unfocus();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已保存')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失败：$error')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
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
            style: textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
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
        ],
      ),
    );
  }
}
