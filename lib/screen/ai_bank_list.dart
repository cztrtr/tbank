import 'package:flutter/material.dart';

import '../services/ai_question_generator.dart';

/// AI 出题 / 拍书出题页共用的「已生成题库」列表。
///
/// 按 `topic` 分组；每行可以打开练习、编辑题目，拍书出题页还可以彻底删除。
class AiBankList extends StatelessWidget {
  const AiBankList({
    super.key,
    required this.banks,
    required this.loading,
    required this.emptyText,
    required this.onOpen,
    this.error,
    this.onEdit,
    this.onDelete,
    this.deletingPath,
    this.subtitleBuilder,
  });

  final List<AiBankInfo> banks;
  final bool loading;
  final String emptyText;
  final String? error;
  final void Function(AiBankInfo bank) onOpen;
  final void Function(AiBankInfo bank)? onEdit;
  final Future<void> Function(AiBankInfo bank)? onDelete;
  final String? deletingPath;
  final String Function(AiBankInfo bank)? subtitleBuilder;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;

    if (loading) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    if (error != null) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          error!,
          style: TextStyle(fontSize: 13, color: colorScheme.onErrorContainer),
        ),
      );
    }

    if (banks.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Center(
          child: Text(
            emptyText,
            style: TextStyle(color: colorScheme.onSurfaceVariant),
          ),
        ),
      );
    }

    final Map<String, List<AiBankInfo>> groups = <String, List<AiBankInfo>>{};
    for (final AiBankInfo bank in banks) {
      groups.putIfAbsent(bank.topic, () => <AiBankInfo>[]).add(bank);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final MapEntry<String, List<AiBankInfo>> group
            in groups.entries) ...<Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 12, 0, 4),
            child: Row(
              children: <Widget>[
                Icon(
                  Icons.folder_outlined,
                  size: 18,
                  color: colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    group.key,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
          for (final AiBankInfo bank in group.value)
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                leading: Icon(Icons.quiz_outlined, color: colorScheme.primary),
                title: Text(
                  bank.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  subtitleBuilder?.call(bank) ?? '${bank.questionCount} 题',
                  style: TextStyle(
                    fontSize: 12,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    if (onEdit != null)
                      IconButton(
                        tooltip: '管理题目',
                        onPressed: () => onEdit!(bank),
                        icon: const Icon(Icons.edit_note, size: 20),
                      ),
                    if (onDelete != null)
                      IconButton(
                        tooltip: '彻底删除',
                        onPressed: deletingPath == bank.path
                            ? null
                            : () => onDelete!(bank),
                        icon: deletingPath == bank.path
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Icon(
                                Icons.delete_outline,
                                size: 20,
                                color: colorScheme.error,
                              ),
                      ),
                  ],
                ),
                onTap: () => onOpen(bank),
              ),
            ),
        ],
      ],
    );
  }
}
