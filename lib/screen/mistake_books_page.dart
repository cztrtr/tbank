import 'dart:io';

import 'package:flutter/material.dart';

import '../models/question_bank_file.dart';
import '../services/ai_question_generator.dart';
import '../services/app_config.dart';
import '../services/bank_io.dart';
import '../services/mistake_books.dart';
import 'practice_page.dart';

/// 错题本二级页面：列出 Alpha、Beta…… 各本错题本。
///
/// 进入时先读已有本子立即展示，再在后台扫一遍所有题库收新错题；
/// 列表按「父文件夹 → 题库子文件夹 → 错题本」三级展示，
/// 父文件夹由当前题库目录配置反查得到（见 [_loadGroupSources]）。
class MistakeBooksPage extends StatefulWidget {
  const MistakeBooksPage({super.key});

  @override
  State<MistakeBooksPage> createState() => _MistakeBooksPageState();
}

/// 一个错题本分组的来源信息。
class _GroupSource {
  const _GroupSource({required this.ref, this.parentKey, this.parentLabel});

  /// 源题库目录引用（桌面路径或 SAF URI）。
  final String ref;

  /// 父文件夹分组键；null 表示解析不出（例如目录已被移除）。
  final String? parentKey;

  /// 父文件夹展示名。
  final String? parentLabel;
}

class _MistakeBooksPageState extends State<MistakeBooksPage> {
  bool _loading = true; // 首次列表是否还在读
  bool _collecting = false; // 后台收集新错题是否进行中
  String? _error; // 加载失败提示；null 表示没有错误
  List<MistakeBookInfo> _books = const <MistakeBookInfo>[]; // 已加载的各本错题本

  /// 分组名 → 源题库目录；用于把「组织学」这类分组挂到父文件夹下。
  Map<String, _GroupSource> _groupSources = const <String, _GroupSource>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _collecting = false;
    });

    // 先读已有本子让页面秒开；扫描题库收集新错题放到后台
    try {
      final List<MistakeBookInfo> books = await MistakeBooks.list();
      final Map<String, _GroupSource> sources = await _loadGroupSources();
      if (!mounted) return;
      setState(() {
        _books = books;
        _groupSources = sources;
        _loading = false;
        _collecting = true;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '加载错题本失败：$error';
        _loading = false;
      });
      return;
    }

    try {
      final int added = await MistakeBooks.collectFromBanks();
      final List<MistakeBookInfo> updated = await MistakeBooks.list();
      if (!mounted) return;
      setState(() {
        _books = updated;
        _collecting = false;
      });

      if (added > 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已收录 $added 道新错题')),
        );
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _collecting = false);
      debugPrint('收集错题失败：$error');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('收集新错题失败，稍后重试')),
      );
    }
  }

  /// 用当前题库目录配置，反查每个错题本分组的源目录和父文件夹。
  ///
  /// 错题本只保存了「题库文件夹名」（`mistakes/<文件夹名>/`），
  /// 这里按同样的规则重新推导：用户添加的目录 + 内置 AI 题库目录。
  /// 目录被移除或改名后找不到来源的分组，会退回按分组名单独显示。
  Future<Map<String, _GroupSource>> _loadGroupSources() async {
    final Map<String, _GroupSource> sources = <String, _GroupSource>{};

    void add(String directoryRef, String groupName) {
      if (groupName.isEmpty || sources.containsKey(groupName)) return;
      final ({String key, String label})? parent = BankIo.parentOf(
        directoryRef,
      );
      sources[groupName] = _GroupSource(
        ref: directoryRef,
        parentKey: parent?.key,
        parentLabel: parent?.label,
      );
    }

    for (final String dirRef in AppConfig.questionBankDirsNotifier.value) {
      add(dirRef, BankIo.displayNameOf(dirRef));
    }

    try {
      for (final ({String name, String path}) topic
          in await AiQuestionGenerator.listTopicDirectories()) {
        add(topic.path, topic.name);
      }
      for (final QuestionBankFile file
          in await AiQuestionGenerator.listBankFiles()) {
        add(file.directoryRef, file.directoryName ?? '');
      }
    } catch (error) {
      debugPrint('读取 AI 题库目录失败：$error');
    }

    return sources;
  }

  /// 打开某一本开始练习，练完回来刷新完成状态。
  Future<void> _open(MistakeBookInfo book) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PracticePage(
          // 配图就在本子所在文件夹里（可能是分组子文件夹）
          bank: book.toBankFile(File(book.path).parent.path),
        ),
      ),
    );

    // 错题本每题都会回写源文件，但最后一题的写入可能还在队列里，
    // 稍等一下再读，避免读到旧数据
    await Future<void>.delayed(const Duration(milliseconds: 200));
    if (mounted) await _load();
  }

  /// 删除一本错题本：二次确认后连同配图一起删，再刷新列表。
  ///
  /// 被删的题会记入「已删除来源」清单，不会在刷新时被重新收集回来。
  Future<void> _delete(MistakeBookInfo book) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('删除错题本'),
        content: Text(
          '将删除《${book.name}》及其 ${book.total} 道错题和配图。\n\n'
          '原题库里的题目和统计不受影响，这些题之后也不会再自动收进错题本。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );

    if (!mounted || confirmed != true) return;

    try {
      await MistakeBooks.deleteBook(book);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('已删除《${book.name}》')));
      await _load();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('删除失败：$error')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('错题本')),
      body: Column(
        children: <Widget>[
          // 后台收集时只在顶部显示一条细进度，不挡住已加载的列表
          if (_collecting) const LinearProgressIndicator(minHeight: 2),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildBody() {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;

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
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(color: colorScheme.error),
              ),
              const SizedBox(height: 12),
              FilledButton(onPressed: _load, child: const Text('重试')),
            ],
          ),
        ),
      );
    }

    if (_books.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                Icons.check_circle_outline,
                size: 48,
                color: colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 12),
              Text(
                '还没有错题',
                style: TextStyle(color: colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 6),
              Text(
                '练习中答错的题会自动收进这里',
                style: TextStyle(
                  fontSize: 12,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      );
    }

    // 父文件夹 → 题库子文件夹 → 错题本
    final Map<String, String> parentLabels = <String, String>{};
    final Set<String> virtualParents = <String>{};
    final Map<String, Map<String, List<MistakeBookInfo>>> tree =
        <String, Map<String, List<MistakeBookInfo>>>{};

    for (final MistakeBookInfo book in _books) {
      final _GroupSource? source = _groupSources[book.groupName];
      final String parentKey;
      final String parentLabel;
      if (book.groupName.isEmpty) {
        // 老版本直接放在根目录的本子：单独一组「未分组」
        parentKey = '';
        parentLabel = '未分组';
      } else if (source?.parentKey != null) {
        parentKey = source!.parentKey!;
        parentLabel = source.parentLabel ?? book.groupName;
      } else {
        // 找不到源目录（目录被移除/改名）：用自己的分组名当父级
        parentKey = 'group:${book.groupName}';
        parentLabel = book.groupName;
      }

      // 没有真实父级时不画子文件夹标题，避免两行同名
      if (parentKey == '' || source?.parentKey == null) {
        virtualParents.add(parentKey);
      }
      parentLabels.putIfAbsent(parentKey, () => parentLabel);
      tree
          .putIfAbsent(parentKey, () => <String, List<MistakeBookInfo>>{})
          .putIfAbsent(book.groupName, () => <MistakeBookInfo>[])
          .add(book);
    }

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: <Widget>[
        for (final MapEntry<String, Map<String, List<MistakeBookInfo>>> parent
            in tree.entries) ...<Widget>[
          // 父文件夹标题
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Row(
              children: <Widget>[
                Icon(
                  Icons.folder_open_outlined,
                  size: 20,
                  color: colorScheme.primary,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    parentLabels[parent.key]!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: colorScheme.onSurface,
                    ),
                  ),
                ),
              ],
            ),
          ),

          for (final MapEntry<String, List<MistakeBookInfo>> child
              in parent.value.entries) ...<Widget>[
            // 题库子文件夹标题（没有父级时省略）
            if (!virtualParents.contains(parent.key))
              Padding(
                padding: const EdgeInsets.fromLTRB(30, 10, 16, 2),
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
                        _childLabelOf(child.key),
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

            // 子文件夹里的各本错题本
            for (final MistakeBookInfo book in child.value)
              Padding(
                padding: EdgeInsets.only(
                  left: virtualParents.contains(parent.key) ? 12 : 44,
                ),
                child: _buildBookTile(colorScheme, book),
              ),
          ],
        ],
      ],
    );
  }

  /// 子文件夹展示名：优先用源目录的末段（AI 二级目录的分组名形如
  /// `主题/子主题`，直接显示会有两段），找不到来源时退回分组名。
  String _childLabelOf(String groupName) {
    final _GroupSource? source = _groupSources[groupName];
    if (source == null) return groupName;
    final String name = BankIo.displayNameOf(source.ref);
    return name.isEmpty ? groupName : name;
  }

  /// 单本错题本列表项：组内缩进，保持一致的本子样式。
  Widget _buildBookTile(ColorScheme colorScheme, MistakeBookInfo book) {
    final bool finished = book.isFinished;

    return ListTile(
      leading: Icon(
        finished ? Icons.check_circle : Icons.menu_book_outlined,
        color: finished ? colorScheme.primary : colorScheme.onSurfaceVariant,
      ),
      title: Text(book.name),
      subtitle: Text('${book.total} 题'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              Text(
                finished ? '已完成' : '未完成',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: finished
                      ? colorScheme.primary
                      : colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '${book.completed}/${book.total}',
                style: TextStyle(
                  fontSize: 12,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(width: 4),
          IconButton(
            tooltip: '删除错题本',
            onPressed: () => _delete(book),
            icon: Icon(Icons.delete_outline, color: colorScheme.error),
          ),
        ],
      ),
      onTap: () => _open(book),
    );
  }
}
