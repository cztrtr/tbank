import 'dart:io';

import 'package:flutter/material.dart';

import '../services/mistake_books.dart';
import 'practice_page.dart';

/// 错题本二级页面：列出 Alpha、Beta…… 各本错题本。
///
/// 每次进入都会先扫一遍所有题库，把新答错的题收进来，再展示列表。
class MistakeBooksPage extends StatefulWidget {
  const MistakeBooksPage({super.key});

  @override
  State<MistakeBooksPage> createState() => _MistakeBooksPageState();
}

class _MistakeBooksPageState extends State<MistakeBooksPage> {
  bool _loading = true; // 是否正在收集错题并读取列表
  String? _error; // 加载失败提示；null 表示没有错误
  List<MistakeBookInfo> _books = const <MistakeBookInfo>[]; // 已加载的各本错题本

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
      // 先收集新的错题，再读列表
      await MistakeBooks.collectFromBanks();
      final List<MistakeBookInfo> books = await MistakeBooks.list();
      if (!mounted) return;
      setState(() {
        _books = books;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '加载错题本失败：$error';
        _loading = false;
      });
    }
  }

  /// 打开某一本开始练习，练完回来刷新完成状态。
  Future<void> _open(MistakeBookInfo book) async {
    final Directory dir = await MistakeBooks.directory();
    if (!mounted) return;

    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PracticePage(bank: book.toBankFile(dir.path)),
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
      body: _buildBody(),
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

    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _books.length,
      separatorBuilder: (_, _) => const Divider(height: 1, indent: 16),
      itemBuilder: (BuildContext context, int index) {
        final MistakeBookInfo book = _books[index];
        final bool finished = book.isFinished;

        return ListTile(
          leading: Icon(
            finished ? Icons.check_circle : Icons.menu_book_outlined,
            color: finished
                ? colorScheme.primary
                : colorScheme.onSurfaceVariant,
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
      },
    );
  }
}
