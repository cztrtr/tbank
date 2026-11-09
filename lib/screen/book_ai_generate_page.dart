import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../services/ai_question_generator.dart';
import '../services/ds_api_service.dart';
import '../services/plugin_manager.dart';
import 'plugin_type_selector.dart';

/// 拍书出题页。
///
/// 用户拍 / 选教材上的**题目**或**知识点讲解**图片，补充具体出题要求，
/// AI 识别图片内容后生成练习题。保存位置可以自定义：
/// `Question/<一级目录>[/<二级目录>]/<文件名>.json`，
/// 生成后到「管理」页即可看到并练习。
///
/// 同一个位置重复生成**不会覆盖**旧题库：同名文件已存在时自动改用
/// `<名字>-2`、`<名字>-3`…。页面下方还列出 `Question/` 里已有的全部题库，
/// 可二次确认后彻底删除（连同空目录一起清理）。
class BookAiGeneratePage extends StatefulWidget {
  const BookAiGeneratePage({super.key});

  @override
  State<BookAiGeneratePage> createState() => _BookAiGeneratePageState();
}

class _BookAiGeneratePageState extends State<BookAiGeneratePage> {
  static const int _maxImages = 3; // 一次最多拍/选几张图
  static const int _maxImageBytes = 5 * 1024 * 1024; // 单张 5 MB
  static const int _maxTotalBytes = 10 * 1024 * 1024; // 合计 10 MB

  final TextEditingController _topicController = TextEditingController(
    text: '拍书出题',
  );
  final TextEditingController _subTopicController = TextEditingController();
  final TextEditingController _fileNameController = TextEditingController();
  final TextEditingController _requirementsController = TextEditingController();

  final List<Uint8List> _images = <Uint8List>[]; // 已选图片

  bool _loadingPlugins = true;
  List<PluginManifest> _plugins = <PluginManifest>[];
  PluginManifest? _plugin;
  final Set<String> _selectedTypes = <String>{};
  int _count = 10;

  bool _generating = false;
  ({int finished, int total})? _progress;
  String? _error;
  List<AiBankInfo> _saved = const <AiBankInfo>[];

  /// 页面下方「已生成的题库」：App 内置目录 `Question/` 里的全部文件。
  bool _loadingBanks = true;
  String? _banksError;
  List<AiBankInfo> _banks = const <AiBankInfo>[];

  /// 正在删除的文件路径，用于禁用按钮、防止连点重复删。
  String? _deletingPath;

  @override
  void initState() {
    super.initState();
    _loadPlugins();
    _loadBanks();
  }

  Future<void> _loadPlugins() async {
    try {
      final List<PluginManifest> plugins = await PluginManager.list();
      if (!mounted) return;
      PluginManifest? initial;
      for (final PluginManifest item in plugins) {
        if (item.builtin) {
          initial = item;
          break;
        }
      }
      initial ??= plugins.isEmpty ? null : plugins.first;
      setState(() {
        _plugins = plugins;
        _plugin = initial;
        _selectedTypes
          ..clear()
          ..addAll(initial?.types ?? const <String>[]);
        _loadingPlugins = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingPlugins = false;
        _error = '读取插件失败：$error';
      });
    }
  }

  void _choosePlugin(PluginManifest? plugin) {
    if (plugin == null) return;
    setState(() {
      _plugin = plugin;
      _selectedTypes
        ..clear()
        ..addAll(plugin.types);
    });
  }

  void _toggleType(String type) {
    setState(() {
      if (!_selectedTypes.add(type)) _selectedTypes.remove(type);
    });
  }

  /// 扫描 `Question/` 下已有的题库，供列表展示与删除。
  Future<void> _loadBanks() async {
    if (mounted) setState(() => _loadingBanks = true);
    try {
      final List<AiBankInfo> banks = await AiQuestionGenerator.listBanks();
      if (!mounted) return;
      setState(() {
        _banks = banks;
        _banksError = null;
        _loadingBanks = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _banksError = '读取已生成题库失败：$error';
        _loadingBanks = false;
      });
    }
  }

  @override
  void dispose() {
    _topicController.dispose();
    _subTopicController.dispose();
    _fileNameController.dispose();
    _requirementsController.dispose();
    super.dispose();
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  /// 拍照或从相册选图；桌面端直接打开文件选择器。
  Future<void> _pickImage() async {
    if (_images.length >= _maxImages) {
      _toast('最多添加 $_maxImages 张图片');
      return;
    }

    final bool isAndroid = defaultTargetPlatform == TargetPlatform.android;
    final ImageSource? source = isAndroid
        ? await showModalBottomSheet<ImageSource>(
            context: context,
            builder: (BuildContext sheetContext) => SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  ListTile(
                    leading: const Icon(Icons.photo_camera_outlined),
                    title: const Text('拍照'),
                    onTap: () =>
                        Navigator.pop(sheetContext, ImageSource.camera),
                  ),
                  ListTile(
                    leading: const Icon(Icons.photo_library_outlined),
                    title: const Text('从相册选择'),
                    onTap: () =>
                        Navigator.pop(sheetContext, ImageSource.gallery),
                  ),
                ],
              ),
            ),
          )
        : ImageSource.gallery;

    if (!mounted || source == null) return;

    try {
      final XFile? picked = await ImagePicker().pickImage(
        source: source,
        maxWidth: 1600, // 压缩到长边 1600，控制请求体积
        imageQuality: 85,
      );
      if (picked == null) return;
      final Uint8List bytes = await picked.readAsBytes();
      if (!mounted || bytes.isEmpty) return;
      if (bytes.length > _maxImageBytes) {
        _toast('图片太大了（超过 5 MB），请换一张');
        return;
      }
      final int total =
          _images.fold<int>(0, (int sum, Uint8List b) => sum + b.length) +
          bytes.length;
      if (total > _maxTotalBytes) {
        _toast('图片合计超过 10 MB，请删掉几张再试');
        return;
      }
      setState(() => _images.add(bytes));
    } catch (error) {
      if (!mounted) return;
      _toast('选择图片失败：$error');
    }
  }

  void _removeImage(int index) {
    setState(() => _images.removeAt(index));
  }

  /// 调 AI 出题并按自定义位置保存。
  Future<void> _generate() async {
    if (_images.isEmpty) {
      _toast('请先拍照或选择图片');
      return;
    }
    final String topic = _topicController.text.trim();
    if (topic.isEmpty) {
      _toast('请填写一级目录名');
      return;
    }
    final PluginManifest? plugin = _plugin;
    if (plugin == null) {
      _toast('请先选择出题插件');
      return;
    }
    if (_selectedTypes.isEmpty) {
      _toast('至少选择一种题型');
      return;
    }

    final List<PluginTypeInfo> selectedTypes = plugin.typeInfos
        .where((PluginTypeInfo type) => _selectedTypes.contains(type.id))
        .toList();

    FocusScope.of(context).unfocus();
    setState(() {
      _generating = true;
      _error = null;
      _progress = null;
      _saved = const <AiBankInfo>[];
    });

    final List<AiBankInfo> saved = <AiBankInfo>[];

    try {
      // 先定好这次生成用的基名：目录里已有同名文件时会自动改成
      // `<名字>-2`、`<名字>-3`…，所以重复生成只是新增，不会覆盖旧题库。
      final String baseName = await AiQuestionGenerator.reserveBaseName(
        topic: topic,
        subTopic: _subTopicController.text,
        baseName: _fileNameController.text,
      );
      if (!mounted) return;

      final List<Map<String, dynamic>> questions =
          await AiQuestionGenerator.generateWithCoverage(
            plugin: plugin,
            types: selectedTypes,
            target: _count,
            request: (PluginTypeInfo type, int count) {
              return DsApiService.generateQuestionsFromImages(
                images: _images,
                requirements: _requirementsController.text,
                types: <String>[type.id],
                count: count,
                typeSpec: AiQuestionGenerator.buildTypeSpec(<PluginTypeInfo>[
                  type,
                ]),
              );
            },
            onProgress: (int finished, int total) {
              if (!mounted) return;
              setState(() => _progress = (finished: finished, total: total));
            },
          );

      if (!mounted) return;
      for (int i = 0; i < questions.length; i++) {
        questions[i]['id'] = 'Q${(i + 1).toString().padLeft(3, '0')}';
      }

      for (
        int start = 0, batchIndex = 1;
        start < questions.length;
        start += AiQuestionGenerator.perBook, batchIndex++
      ) {
        final int end = start + AiQuestionGenerator.perBook > questions.length
            ? questions.length
            : start + AiQuestionGenerator.perBook;
        saved.add(
          await AiQuestionGenerator.saveBatchTo(
            topic: topic,
            subTopic: _subTopicController.text,
            baseName: baseName,
            questions: questions.sublist(start, end),
            batchIndex: batchIndex,
            plugin: plugin.id,
            pluginVersion: plugin.apiVersion,
          ),
        );
      }

      if (!mounted) return;
      setState(() => _saved = saved);
      _toast('已生成 ${questions.length} 道题，保存为 ${saved.length} 个文件');
      await _loadBanks();
    } on DsApiException catch (error) {
      if (!mounted) return;
      setState(() => _error = error.message);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = '出题失败：$error');
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    final TextTheme textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('拍书出题')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          // ---- 图片 ----
          Text(
            '题目 / 知识点图片',
            style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            '拍教材上的题目或知识点讲解都可以；最多 $_maxImages 张。',
            style: TextStyle(
              fontSize: 12,
              height: 1.5,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (int i = 0; i < _images.length; i++)
                _buildThumb(i, colorScheme),
              if (_images.length < _maxImages) _buildAddButton(),
            ],
          ),
          const SizedBox(height: 16),

          // ---- 出题要求 ----
          Text(
            '出题要求',
            style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _requirementsController,
            enabled: !_generating,
            minLines: 3,
            maxLines: 6,
            decoration: InputDecoration(
              hintText: '如：模仿图中题目出 10 道类似的计算题，难度稍高',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
          const SizedBox(height: 16),

          // ---- 保存位置 ----
          Text(
            '保存位置',
            style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Text(
            '题目会保存到 App 题库目录：一级目录 / 二级目录 / 文件名。'
            '生成后到「管理」页即可找到。',
            style: TextStyle(
              fontSize: 12,
              height: 1.5,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _topicController,
            enabled: !_generating,
            decoration: InputDecoration(
              labelText: '一级目录（必填）',
              hintText: '如：拍书-高数',
              isDense: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _subTopicController,
            enabled: !_generating,
            decoration: InputDecoration(
              labelText: '二级目录（可选）',
              hintText: '如：期中卷',
              isDense: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _fileNameController,
            enabled: !_generating,
            decoration: InputDecoration(
              labelText: '文件名（可选）',
              hintText: '默认自动生成，如：期中卷-20251102',
              isDense: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
          const SizedBox(height: 16),

          // ---- 插件与题型 ----
          PluginTypeSelector(
            plugins: _plugins,
            selectedPlugin: _plugin,
            selectedTypes: _selectedTypes,
            enabled: !_generating,
            loading: _loadingPlugins,
            onPluginChanged: _choosePlugin,
            onTypeToggled: _toggleType,
          ),
          const SizedBox(height: 16),

          // ---- 数量 ----
          Text(
            '题目数量',
            style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          DropdownButtonFormField<int>(
            initialValue: _count,
            decoration: InputDecoration(
              isDense: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            items: <DropdownMenuItem<int>>[
              for (final int value in const <int>[
                5,
                10,
                15,
                20,
                25,
                30,
                40,
                50,
              ])
                DropdownMenuItem<int>(value: value, child: Text('$value 道')),
            ],
            onChanged: _generating
                ? null
                : (int? value) {
                    if (value != null) setState(() => _count = value);
                  },
          ),
          const SizedBox(height: 16),

          // ---- 生成 ----
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _generating ? null : _generate,
              icon: _generating
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.auto_awesome, size: 20),
              label: Text(_generating ? 'AI 正在识别并出题…' : '开始出题'),
            ),
          ),
          if (_generating) ...<Widget>[
            const SizedBox(height: 10),
            Text(
              _progress == null
                  ? '正在识别图片并生成，首批通常需要 30~90 秒'
                  : '正在生成：已完成 ${_progress!.finished} / '
                        '${_progress!.total} 道',
              style: TextStyle(
                fontSize: 12,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            if (_progress != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: LinearProgressIndicator(
                  value: _progress!.finished / _progress!.total,
                ),
              ),
          ],
          if (_error != null) ...<Widget>[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                _error!,
                style: TextStyle(
                  fontSize: 13,
                  color: colorScheme.onErrorContainer,
                ),
              ),
            ),
          ],
          if (_saved.isNotEmpty) ...<Widget>[
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '已保存 ${_saved.length} 个题库文件',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: colorScheme.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(height: 4),
                  for (final AiBankInfo bank in _saved)
                    Text(
                      '• ${bank.topic}/${bank.fileName}'
                      '（${bank.questionCount} 题）',
                      style: TextStyle(
                        fontSize: 12,
                        color: colorScheme.onPrimaryContainer,
                      ),
                    ),
                  const SizedBox(height: 4),
                  Text(
                    '到「管理」页刷新即可看到并练习',
                    style: TextStyle(
                      fontSize: 12,
                      color: colorScheme.onPrimaryContainer,
                    ),
                  ),
                ],
              ),
            ),
          ],

          // ---- 已生成的题库（含历史拍书题目，可彻底删除）----
          const SizedBox(height: 24),
          const Divider(),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '已生成的题库',
                  style: textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              IconButton(
                tooltip: '刷新列表',
                onPressed: _loadingBanks ? null : _loadBanks,
                icon: const Icon(Icons.refresh, size: 20),
              ),
            ],
          ),
          Text(
            '列出 App 内置题库目录「Question」里的全部文件。'
            '点右侧垃圾桶会彻底删除磁盘上的 .json（不可恢复）：'
            '删除后「管理」页和统计里都不再显示它，'
            '已经收进错题本的题目会保留。',
            style: TextStyle(
              fontSize: 12,
              height: 1.5,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          ..._buildBankList(colorScheme),
        ],
      ),
    );
  }

  /// 页面下方的已生成题库列表：按目录分组，每行可彻底删除。
  List<Widget> _buildBankList(ColorScheme colorScheme) {
    if (_loadingBanks) {
      return <Widget>[
        const Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    }

    if (_banksError != null) {
      return <Widget>[
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: colorScheme.errorContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            _banksError!,
            style: TextStyle(fontSize: 13, color: colorScheme.onErrorContainer),
          ),
        ),
      ];
    }

    if (_banks.isEmpty) {
      return <Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 20),
          child: Center(
            child: Text(
              '还没有生成过题库',
              style: TextStyle(color: colorScheme.onSurfaceVariant),
            ),
          ),
        ),
      ];
    }

    // 按「一级目录 / 二级目录」分组，顺序与 listBanks 一致
    final Map<String, List<AiBankInfo>> groups = <String, List<AiBankInfo>>{};
    for (final AiBankInfo bank in _banks) {
      groups.putIfAbsent(bank.topic, () => <AiBankInfo>[]).add(bank);
    }

    return <Widget>[
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
                '${bank.questionCount} 题 · ${_formatTime(bank.modifiedAt)}',
                style: TextStyle(
                  fontSize: 12,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              trailing: IconButton(
                tooltip: '彻底删除',
                onPressed: _deletingPath == bank.path
                    ? null
                    : () => _deleteBank(bank),
                icon: _deletingPath == bank.path
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        Icons.delete_outline,
                        size: 20,
                        color: colorScheme.error,
                      ),
              ),
            ),
          ),
      ],
    ];
  }

  /// 彻底删除一份已生成的题库：二次确认后删文件，并清理空目录。
  Future<void> _deleteBank(AiBankInfo bank) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('彻底删除题库'),
        content: Text(
          '将从 App 题库目录永久删除这个文件，无法恢复：\n\n'
          '目录：${bank.topic}\n'
          '文件：${bank.fileName}\n'
          '题目：${bank.questionCount} 道\n\n'
          '删除后「管理」页和统计里都不再显示它；'
          '已经收进错题本的题目会保留。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );

    if (!mounted || confirmed != true) return;

    setState(() => _deletingPath = bank.path);
    try {
      await AiQuestionGenerator.deleteBank(bank);
      if (!mounted) return;
      _toast('已删除《${bank.displayName}》');
    } catch (error) {
      if (!mounted) return;
      _toast('删除失败：$error');
    } finally {
      if (mounted) setState(() => _deletingPath = null);
    }

    if (!mounted) return;
    await _loadBanks();
  }

  /// 列表里的修改时间：同一天只显示时分，跨天带上月日。
  String _formatTime(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    final DateTime now = DateTime.now();
    final String clock = '${two(time.hour)}:${two(time.minute)}';
    final bool sameDay =
        time.year == now.year && time.month == now.month && time.day == now.day;
    return sameDay ? clock : '${two(time.month)}-${two(time.day)} $clock';
  }

  /// 一张已选图片的缩略图，右上角可删除。
  Widget _buildThumb(int index, ColorScheme colorScheme) {
    return Stack(
      children: <Widget>[
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Image.memory(
            _images[index],
            width: 96,
            height: 96,
            fit: BoxFit.cover,
            cacheWidth: 192,
          ),
        ),
        Positioned(
          top: 2,
          right: 2,
          child: Material(
            color: Colors.black54,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: _generating ? null : () => _removeImage(index),
              child: const Padding(
                padding: EdgeInsets.all(2),
                child: Icon(Icons.close, size: 16, color: Colors.white),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 添加图片的虚线方框按钮。
  Widget _buildAddButton() {
    return SizedBox(
      width: 96,
      height: 96,
      child: OutlinedButton(
        onPressed: _generating ? null : _pickImage,
        style: OutlinedButton.styleFrom(
          padding: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
        child: const Icon(Icons.add_a_photo_outlined),
      ),
    );
  }
}
