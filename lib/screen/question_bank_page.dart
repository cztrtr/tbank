import 'dart:async'; // unawaited
import 'dart:io'; // Directory、File、FileSystemException、Platform

import 'package:file_picker/file_picker.dart'; // 系统目录选择器
import 'package:flutter/material.dart';

import '../models/question_bank_file.dart'; // 公共的题库文件模型
import '../services/app_config.dart'; // 题库目录的全局列表
import '../services/storage_permission.dart'; // 存储权限检查与申请

/// 题库管理页：
/// - 右上角加号添加题库目录；
/// - 扫描目录里的 .json 文件并列出；
/// - 点击某个 .json 交给父页面，切到练习页。
///
/// 权限采用按需申请：进页面先尝试扫描，失败时显示“授权并重试”；
/// 点加号时也会先确保权限，再打开系统目录选择器。
class QuestionBankPage extends StatefulWidget {
  const QuestionBankPage({super.key, required this.onOpenBank});

  /// 选中题库时通知 MainScreen；由它保存选中项并切到练习页。
  final ValueChanged<QuestionBankFile> onOpenBank;

  @override
  State<QuestionBankPage> createState() => _QuestionBankPageState();
}

class _QuestionBankPageState extends State<QuestionBankPage> {
  bool _isPicking = false; // 是否正在等系统选择器或权限界面返回，防止连点

  List<QuestionBankFile> _files = <QuestionBankFile>[]; // 扫描到的题库文件
  bool _isScanning = false; // 是否正在扫描
  String? _scanError; // 读取失败的提示；null 表示没有错误
  int _scanGeneration = 0; // 扫描序号，防止旧扫描结果覆盖新结果

  bool _requestingPermission = false; // 防止权限弹窗被重复触发

  @override
  void initState() {
    super.initState();
    // 目录增删后自动重新扫描
    AppConfig.questionBankDirsNotifier.addListener(_onDirsChanged);

    // 启动先尝试扫描；没权限时会进入错误分支，
    // 等用户点“授权并重试”或右上角加号时再申请权限
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

  /// 申请存储权限；拿到权限后重新扫描，拿不到就把错误显示在页面上。
  Future<void> _ensurePermissionThenScan() async {
    if (_requestingPermission) return; // 防止按钮连点
    _requestingPermission = true;

    try {
      final granted = await StoragePermission.ensure(context);
      if (!mounted) return;

      if (!granted) {
        setState(() => _scanError = '没有存储权限，无法读取题库目录');
        return;
      }

      await _scanFiles();
    } catch (error) {
      if (!mounted) return;
      setState(() => _scanError = '申请存储权限失败：$error');
    } finally {
      _requestingPermission = false;
    }
  }

  /// 遍历所有题库目录，收集 .json 文件。
  Future<void> _scanFiles() async {
    final generation = ++_scanGeneration; // 本次扫描编号

    if (mounted) {
      setState(() {
        _isScanning = true;
        _scanError = null; // 清掉上一次的错误，避免旧提示残留
      });
    }

    // 从全局 notifier 取最新目录，保证加号新增的目录立即可见
    final dirs = AppConfig.questionBankDirsNotifier.value;
    final files = <QuestionBankFile>[];
    final seenPaths = <String>{}; // 按完整路径去重
    final errors = <String>[];

    for (final dirPath in dirs) {
      try {
        final dir = Directory(dirPath);
        if (!await dir.exists()) {
          errors.add('目录不存在：$dirPath');
          continue;
        }

        // 只扫当前层；想连子目录一起扫，把 recursive: true 加上
        await for (final entity in dir.list(followLinks: false)) {
          if (entity is! File) continue; // 跳过子目录和链接

          // 取文件名，兼容 Windows 的 \ 分隔符
          final name = entity.path.split(Platform.pathSeparator).last;

          // 扩展名统一转小写，.JSON 也能识别
          if (!name.toLowerCase().endsWith('.json')) continue;

          // 同一路径只收一次
          if (!seenPaths.add(entity.path)) continue;

          files.add(QuestionBankFile(name: name, path: entity.path));
        }
      } on FileSystemException catch (error) {
        // 没权限或读取失败：只记录，不影响其他目录
        errors.add('读取失败：$dirPath（${error.message}）');
      }
    }

    // 按文件名排序，保证展示顺序稳定
    files.sort(
      (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );

    // 页面已销毁，或已经开始了更新的扫描：丢弃这次结果
    if (!mounted || generation != _scanGeneration) return;

    setState(() {
      _files = files;
      _scanError = errors.isEmpty ? null : errors.join('\n');
      _isScanning = false;
    });
  }

  /// 调起系统目录选择器，把选中的目录加入题库目录列表。
  Future<void> _pickDirectory() async {
    if (_isPicking) return;
    setState(() => _isPicking = true);

    try {
      // 扫描和后续读写都需要存储权限，先确保授权
      final granted = await StoragePermission.ensure(context);
      if (!mounted) return;

      if (!granted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('没有存储权限，无法添加题库目录')),
        );
        return;
      }

      // 返回选中的目录绝对路径；用户取消时返回 null
      final String? path = await FilePicker.getDirectoryPath(
        dialogTitle: '选择题库目录',
      );

      if (!mounted) return;
      if (path == null) return; // 用户取消，或目录无法解析成路径

      // 写入 config.json，并触发全局 notifier；上面的监听会自动重新扫描
      await AppConfig.addQuestionBankDir(path);
      if (!mounted) return;

      debugPrint('选中的题库目录：$path');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已添加目录：$path')),
      );
    } catch (error) {
      // 选择器或权限流程异常，提示用户而不是静默失败
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('添加题库目录失败：$error')),
      );
    } finally {
      if (mounted) setState(() => _isPicking = false);
    }
  }

  /// 统一路径分隔符并去掉末尾斜杠，用于比较配置里的目录记录。
  ///
  /// 题库目录来自系统选择器，末尾可能带斜杠，和 File.parent.path 不一定完全一致。
  String _normalizePath(String path) {
    var result = path.replaceAll('\\', '/');
    while (result.length > 1 && result.endsWith('/')) {
      result = result.substring(0, result.length - 1);
    }
    return result;
  }

  /// 从 config.json 移除某个题库文件所在的目录记录。
  ///
  /// 只删配置记录，不删除磁盘上的目录或 .json 文件。
  /// 如果该目录下还有其它题库文件，它们也会一起从列表里消失。
  Future<void> _removeDirectoryFor(QuestionBankFile file) async {
    final dirPath = File(file.path).parent.path;
    final dirs = AppConfig.questionBankDirsNotifier.value;

    // 找到配置里实际存的那一条，避免末尾斜杠导致删除失败
    String? configuredDir;
    for (final dir in dirs) {
      if (dir == dirPath ||
          _normalizePath(dir) == _normalizePath(dirPath)) {
        configuredDir = dir;
        break;
      }
    }

    if (configuredDir == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没有找到对应的目录记录，列表可能已经刷新')),
      );
      return;
    }

    // 二次确认，明确告诉用户不会删除题目文件
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('移除题库目录'),
        content: Text(
          '将从 config.json 中移除这个目录记录：\n\n'
          '$configuredDir\n\n'
          '不会删除目录里的任何文件。\n'
          '如果该目录下还有其它 .json，它们也会一起从列表中消失。',
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
    await AppConfig.removeQuestionBankDir(configuredDir);
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已移除目录记录，题库文件未被删除')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('题库管理'), // 左上角标题
        actions: <Widget>[
          IconButton(
            tooltip: '添加题库目录',
            onPressed: _isPicking ? null : _pickDirectory,
            icon: _isPicking
                // 等待系统选择器或权限界面时显示转圈
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

  /// 按“扫描中 / 权限或读取错误 / 没目录 / 没 json / 文件列表”分支展示。
  Widget _buildBody(ColorScheme colorScheme) {
    final dirs = AppConfig.questionBankDirsNotifier.value;

    // 第一次扫描还没结果时，显示进度圈
    if (_isScanning && _files.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    // 没有任何文件且有错误：通常是没权限，给出重新授权入口
    if (_files.isEmpty && _scanError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                Icons.lock_outline,
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
                // 已授权时只是重新扫描；没授权会先弹权限说明
                onPressed: _ensurePermissionThenScan,
                child: const Text('授权并重试'),
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
        // 部分目录读取失败时的提示，例如某个目录被删掉或权限不足
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
            separatorBuilder: (context, index) =>
                const SizedBox(height: 10),
            itemBuilder: (context, index) {
              final file = _files[index];

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
                    // 只删 config.json 里的目录记录，不删文件
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