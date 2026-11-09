import 'package:flutter/material.dart';

import '../services/plugin_manager.dart';

/// 插件 + 该插件支持题型的通用选择器。
///
/// 出题界面只列插件声明的 type；题型说明也由 manifest 提供，
/// App 不再维护中文标签到内部 type 的映射。
class PluginTypeSelector extends StatelessWidget {
  const PluginTypeSelector({
    super.key,
    required this.plugins,
    required this.selectedPlugin,
    required this.selectedTypes,
    required this.enabled,
    required this.onPluginChanged,
    required this.onTypeToggled,
    this.loading = false,
  });

  final List<PluginManifest> plugins;
  final PluginManifest? selectedPlugin;
  final Set<String> selectedTypes;
  final bool enabled;
  final ValueChanged<PluginManifest?> onPluginChanged;
  final ValueChanged<String> onTypeToggled;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    if (loading) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Text(
          '正在加载插件…',
          style: TextStyle(color: colors.onSurfaceVariant),
        ),
      );
    }
    if (plugins.isEmpty) {
      return Text(
        '还没有安装可用插件',
        style: TextStyle(color: colors.onSurfaceVariant),
      );
    }

    final PluginManifest? plugin = selectedPlugin;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          '出题插件',
          style: Theme.of(context).textTheme.titleMedium
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 6),
        DropdownButtonFormField<String>(
          initialValue: plugin?.id,
          decoration: InputDecoration(
            isDense: true,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
          items: <DropdownMenuItem<String>>[
            for (final PluginManifest item in plugins)
              DropdownMenuItem<String>(
                value: item.id,
                child: Text('${item.name}（${item.id}）'),
              ),
          ],
          onChanged: enabled
              ? (String? id) {
                  if (id == null) return;
                  for (final PluginManifest item in plugins) {
                    if (item.id == id) {
                      onPluginChanged(item);
                      return;
                    }
                  }
                }
              : null,
        ),
        if (plugin != null) ...<Widget>[
          const SizedBox(height: 10),
          Text(
            '${plugin.name} 支持的题型',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          for (final PluginTypeInfo type in plugin.typeInfos)
            CheckboxListTile(
              value: selectedTypes.contains(type.id),
              contentPadding: EdgeInsets.zero,
              dense: true,
              controlAffinity: ListTileControlAffinity.leading,
              title: Text('${type.name} · ${type.id}'),
              subtitle: type.description.isEmpty
                  ? null
                  : Text(
                      type.description,
                      style: const TextStyle(fontSize: 12, height: 1.4),
                    ),
              onChanged: enabled ? (_) => onTypeToggled(type.id) : null,
            ),
        ],
      ],
    );
  }
}
