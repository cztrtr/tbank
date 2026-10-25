import 'dart:async'; // unawaited

import 'package:file_picker/file_picker.dart'; // 桌面端的目录选择器
import 'package:flutter/material.dart';

import '../models/question_bank_file.dart'; // 公共的题库文件模型
import '../services/app_config.dart'; // 题库目录的全局列表
import '../services/bank_io.dart'; // 统一的目录/文件访问入口
import '../services/saf.dart'; // Android 的 SAF 目录选择

/// 题库管理页：
/// - 右上角加号添加题库目录；
/// - 扫描目录里的 .json 文件并列出；
/// - 点击某个 .json 交给父页面，切到练习页。
///
/// 存储访问分两套：
/// - **Android**：SAF。用户通过系统目录选择器授权某个文件夹，应用拿到持久化的
///   tree URI，之后靠 ContentResolver 读写 —— **不需要任何存储权限**。
/// - **桌面**：普通文件路径，仍用 file_picker 选目录。
///
/// 两套实现在 `BankIo` 里收敛，本页不需要区分。
class QuestionBankPage extends StatefulWidget {
  const QuestionBankPage({super.key, required this.onOpenBank});

  /// 选中题库时通知 MainScreen；由它保存选中项并切到练习页。
  final ValueChanged<QuestionBankFile> onOpenBank;

  @override
  State<QuestionBankPage> createState() => _QuestionBankPageState();
}

class _QuestionBankPageState extends State<QuestionBankPage> {
  bool _isPicking = false; // 是否正在等系统选择器返回，防止连点

  List<QuestionBankFile> _files = <QuestionBankFile>[]; // 扫描到的题库文件
  bool _isScanning = false; // 是否正在扫描
  String? _scanError; // 读取失败的提示；null 表示没有错误
  int _scanGeneration = 0; // 扫描序号，防止旧扫描结果覆盖新结果

  @override
  void initState() {
    super.initState();
    // 目录增删后自动重新扫描
    AppConfig.questionBankDirsNotifier.addListener(_onDirsChanged);

    // 启动先扫一次；SAF 授权失效的目录会进入错误提示
    unawaited(_scanFiles());
  }

  @override
  void dispose() {
    // 页面销毁时移除监听，避免 notifier 持有失效回调
    AppConfig.questionBankDirsNotifier.removeListener(_onDirsChanged);
    super.dispose();
  }

  /// 题库目录列表变化（加号新增、删除等）时重新扫描。
  void _onDirsChanged() {
    unawaited(_scanFiles());
  }

  /// 遍历所有题库目录，收集 .json 文件。
  Future<void> _scanFiles() async {
    final int generation = ++_scanGeneration; // 本次扫描编号

    if (mounted) {
      setState(() {
        _isScanning = true;
        _scanError = null; // 清掉上一次的错误，避免旧提示残留
      });
    }

    // 从全局 notifier 取最新目录，保证加号新增的目录立即可见
    final List<String> dirs = AppConfig.questionBankDirsNotifier.value;
    final List<QuestionBankFile> files = <QuestionBankFile>[];
    final Set<String> seen = <String>{}; // 按文件引用去重
    final List<String> errors = <String>[];

    for (final String dirRef in dirs) {
      try {
        // Android 上旧版本存的是绝对路径，SAF 之后已经无法访问
        if (Saf.isSupported && !BankIo.isSafRef(dirRef)) {
          errors.add(
            '「${BankIo.displayNameOf(dirRef)}」是旧版目录记录，'
            '已不再支持路径访问，请删除后重新添加',
          );
          continue;
        }

        final List<QuestionBankFile> found = await BankIo.listJsonFiles(
          dirRef,
          directoryName: BankIo.displayNameOf(dirRef),
        );

        for (final QuestionBankFile file in found) {
          if (seen.add(file.uri)) {
            files.add(file);
          }
        }
      } catch (error) {
        // 授权被撤销、目录被删、读取失败：只记录，不影响其它目录
        errors.add('读取失败：${BankIo.displayNameOf(dirRef)}（$error）');
      }
    }

    // 页面已销毁，或已经开始了更新的扫描：丢弃这次结果
    if (!mounted || generation != _scanGeneration) return;

    setState(() {
      _files = files;
      _scanError = errors.isEmpty ? null : errors.join('\n');
      _isScanning = false;
    });
  }

  /// 添加一个题库目录。
  ///
  /// Android 走 SAF 目录选择器（顺带拿到持久授权）；桌面走 file_picker。
  Future<void> _pickDirectory() async {
    if (_isPicking) return;
    setState(() => _isPicking = true);

    try {
      String? dirRef;
      String? dirName;

      if (Saf.isSupported) {
        final SafDirectory? picked = await Saf.pickDirectory();
        if (!mounted) return;
        if (picked == null) return; // 用户取消

        dirRef = picked.uri;
        dirName = picked.name;
      } else {
        final String? path = await FilePicker.getDirectoryPath(
          dialogTitle: '选择题库目录',
        );
        if (!mounted) return;
        if (path == null) return; // 用户取消

        dirRef = path;
        dirName = BankIo.displayNameOf(path);
      }

      // 已经在列表里就不重复添加，避免重复扫描
      if (AppConfig.questionBankDirsNotifier.value.contains(dirRef)) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('目录「$dirName」已经在列表里了')),
        );
        return;
      }

      // 写入 config.json，并触发全局 notifier；上面的监听会自动重新扫描
      await AppConfig.addQuestionBankDir(dirRef);
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已添加目录：$dirName')),
      );
    } catch (error) {
      // 选择器异常、授权失败等，提示用户而不是静默失败
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('添加题库目录失败：$error')),
      );
    } finally {
      if (mounted) setState(() => _isPicking = false);
    }
  }

  /// 从 config.json 移除某个题库文件所在的目录记录，并释放 SAF 授权。
  ///
  /// 只删配置记录和目录授权，不删除磁盘上的任何文件。
  /// 如果该目录下还有其它题库文件，它们也会一起从列表里消失。
  Future<void> _removeDirectoryFor(QuestionBankFile file) async {
    final String dirRef = file.directoryRef;
    final String dirName = file.directoryName ?? BankIo.displayNameOf(dirRef);

    // 二次确认，明确告诉用户不会删除题目文件
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('移除题库目录'),
        content: Text(
          '将从题库列表中移除这个目录：\n\n'
          '$dirName\n\n'
          '不会删除目录里的任何文件。\n'
          '如果该目录下还有其它 .json，它们也会一起从列表中消失。\n'
          '${Saf.isSupported ? '同时会撤销对本目录的访问授权。' : ''}',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('移除'),
          ),
        ],
      ),
    );

    if (!mounted || confirmed != true) return;

    // 只改配置；notifier 会通知列表重新扫描
    await AppConfig.removeQuestionBankDir(dirRef);
    if (!mounted) return;

    // 还有别的目录记录指向同一位置时，不能撤销授权
    final bool stillUsed =
        AppConfig.questionBankDirsNotifier.value.contains(dirRef);
    if (!stillUsed) {
      await BankIo.releaseDirectory(dirRef);
    }
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已移除目录，题库文件未被删除')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('题库管理'), // 左上角标题
        actions: <Widget>[
          IconButton(
            tooltip: '添加题库目录',
            onPressed: _isPicking ? null : _pickDirectory,
            icon: _isPicking
                // 等待系统选择器时显示转圈
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.add), // 平时显示加号
          ),
          const SizedBox(width: 8), // 右边留一点空隙
        ],
      ),
      body: _buildBody(colorScheme),
    );
  }

  /// 按「扫描中 / 读取错误 / 没目录 / 没 json / 文件列表」分支展示。
  Widget _buildBody(ColorScheme colorScheme) {
    final List<String> dirs = AppConfig.questionBankDirsNotifier.value;

    // 第一次扫描还没结果时，显示进度圈
    if (_isScanning && _files.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    // 没有任何文件且有错误：多半是授权失效或目录被删，给出重新扫描入口
    if (_files.isEmpty && _scanError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                Icons.folder_off_outlined,
                size: 48,
                color: colorScheme.outline,
              ),
              const SizedBox(height: 12),
              Text(
                _scanError!,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _scanFiles,
                child: const Text('重新扫描'),
              ),
            ],
          ),
        ),
      );
    }

    // 一个题库目录都没加
    if (dirs.isEmpty) {
      return const Center(child: Text('还没有题库目录，点右上角 + 添加'));
    }

    // 有目录但里面没有 .json（且没有扫描错误）
    if (_files.isEmpty) {
      return const Center(child: Text('这些目录里没有找到 .json 文件'));
    }

    return Column(
      children: <Widget>[
        // 部分目录读取失败时的提示，例如授权被撤销或目录被删
        if (_scanError != null)
          Container(
            width: double.infinity,
            color: colorScheme.errorContainer,
            padding: const EdgeInsets.all(12),
            child: Text(
              _scanError!,
              style: TextStyle(
                fontSize: 12,
                color: colorScheme.onErrorContainer,
              ),
            ),
          ),

        // 顶部统计
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '共 ${_files.length} 个题库文件',
              style: TextStyle(
                fontSize: 13,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),

        // 题库按钮列表
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: _files.length,
            separatorBuilder: (BuildContext context, int index) =>
                const SizedBox(height: 10),
            itemBuilder: (BuildContext context, int index) {
              final QuestionBankFile file = _files[index];

              return Row(
                children: <Widget>[
                  Expanded(
                    child: OutlinedButton.icon(
                      // 把选中的题库交给父页面；MainScreen 会切到练习页
                      onPressed: () => widget.onOpenBank(file),
                      icon: const Icon(Icons.description_outlined),
                      label: Text(
                        file.name, // 只显示文件名，例如 高数第一章.json
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 14,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    tooltip: '移除该题库目录',
                    // 只删配置记录和目录授权，不删文件
                    onPressed: () => _removeDirectoryFor(file),
                    icon: Icon(
                      Icons.delete_outline,
                      color: colorScheme.error,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}
