// 练习页的完整生命周期：
// 1. 收到 QuestionBankFile 后，把源 json 复制到 App 文档目录；
// 2. 解析成 QuestionBank，逐题展示；
// 3. 每题判分后更新内存统计并写回工作副本；
// 4. 完成整份 / 进入后台 / 页面销毁时，把工作副本回拷到题库文件夹。
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/question_bank.dart';
import '../models/question_bank_file.dart';
import '../services/app_config.dart';
import '../services/ds_api_service.dart';
import '../services/mistake_books.dart';
import '../services/plugin_manager.dart';
import '../services/practice_progress.dart';
import '../services/question_bank_storage.dart';
import 'answer_image_picker.dart';
import 'practice_ai_service.dart';
import 'practice_controller.dart';
import 'practice_persistence.dart';
import 'practice_question_view.dart';
import 'plugin_practice_view.dart';
import '../services/plugin_runtime.dart';

/// 练习页：加载题库、逐题作答、更新统计并回写文件。
///
/// 页面状态分三类：
/// - 加载态：_loading / _error / _questions；
/// - 当前题：_index / _selected / _showAnswer / _answered / _wasCorrect；
/// - 整份进度：_finished / _answeredCount / _correctCount / _syncMessage。
class PracticePage extends StatefulWidget {
  const PracticePage({super.key, this.bank});

  /// 从题库管理页选中的题库文件；null 表示还没选。
  final QuestionBankFile? bank;

  @override
  State<PracticePage> createState() => _PracticePageState();
}

class _PracticePageState extends State<PracticePage>
    with WidgetsBindingObserver {
  /// 保存/回拷/断点都交给它，页面不再自己管计时器和串行队列。
  PracticePersistence? _persistence;

  QuestionBankStorage? get _storage => _persistence?.storage;
  QuestionBank? _questions; // 已读进内存的题库

  /// 当前题库使用的插件 id；standard 走内置 WebView 插件。
  String _pluginId = PluginManager.builtinId;

  /// 当前插件清单，用于校验插件私有数据和取 schema。
  PluginManifest? _pluginManifest;

  bool _loading = false; // 是否正在加载题库
  String? _error; // 加载失败的提示

  /// 答题状态机：题目、当前题号、选中项、已答结果和计数都在这里。
  ///
  /// 页面通过下面的 getter/setter 读写，UI 代码不用关心状态存在哪；
  /// 状态迁移（record / goTo / restart）也由它统一处理，方便单独测试。
  PracticeController _controller = PracticeController();

  int get _index => _controller.index;
  Set<String> get _selected => _controller.selected;
  Map<int, ({bool correct, Set<String> selected})> get _answeredStates =>
      _controller.answeredStates;
  bool get _answered => _controller.answered;
  set _answered(bool value) => _controller.answered = value;
  bool get _wasCorrect => _controller.wasCorrect;
  set _wasCorrect(bool value) => _controller.wasCorrect = value;

  bool _showAnswer = false; // 填空/解释是否已展示答案
  bool _grading = false; // 是否正在等 AI 判分
  bool _aiFallback = false; // AI 判分不可用时，本题退回自判
  int? _aiScore; // 本题的 AI 得分（0-10），仅主观题用
  bool _aiAnalysisLoading = false; // 是否正在请求 AI 解析
  String? _aiAnalysis; // 当前题的 AI 解析文本
  String? _aiAnalysisError; // AI 解析失败原因
  final TextEditingController _answerController =
      TextEditingController(); // 主观题的作答输入

  /// 学生拍照 / 上传的作答图片；AI 判分时会和文字答案一起发送。
  final List<Uint8List> _answerImages = <Uint8List>[];

  bool get _finished => _controller.finished;
  set _finished(bool value) => _controller.finished = value;
  int get _answeredCount => _controller.answeredCount;
  int get _correctCount => _controller.correctCount;
  String? _syncMessage; // 回拷源文件的状态提示

  int _loadToken = 0; // 加载序号，防止旧加载覆盖新加载

  @override
  void initState() {
    super.initState();
    // 监听前后台切换，用于进入后台时回拷文件
    WidgetsBinding.instance.addObserver(this);

    final bank = widget.bank;
    if (bank != null) {
      unawaited(_loadBank(bank));
    }
  }

  @override
  void didUpdateWidget(covariant PracticePage oldWidget) {
    super.didUpdateWidget(oldWidget);

    // IndexedStack 会保留 State，换题库不会重跑 initState，只能在这里感知
    final bank = widget.bank;
    if (bank != null && oldWidget.bank?.uri != bank.uri) {
      unawaited(_loadBank(bank));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 进入后台、被系统回收前，把文档目录里的副本回拷到题库文件夹
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      // 先把防抖队列里的最后一次保存落盘，再回拷
      unawaited(_flushPersist());
      unawaited(_syncBack());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _answerController.dispose();

    // 页面销毁时先保存断点和待写副本，再尝试同步
    unawaited(_saveProgress());
    unawaited(_flushPersist());
    unawaited(_syncBack());
    _persistence?.dispose();
    super.dispose();
  }

  /// 打开题库：源文件复制到文档目录，再解析进内存。
  Future<void> _loadBank(QuestionBankFile file) async {
    // 切换题库前，先把上一个题库还没落盘的改动写完，再同步回去
    await _flushPersist();

    // 首次升级的后台 id 迁移可能正在改写题库文件，等它结束再读，避免读到半截 JSON
    await MistakeBooks.waitForStartupMigration();

    final previousStorage = _storage;
    if (previousStorage != null) {
      await previousStorage.syncBack();
    }
    if (!mounted) return;

    final token = ++_loadToken;

    setState(() {
      // 进入加载态，清空上一份题库的界面状态
      _loading = true;
      _error = null;
      _persistence = null;
      _questions = null;
      _syncMessage = null;
      // 换题库时先换一个空状态机；加载完成后再用新题库和断点初始化
      _controller = PracticeController();
      _resetQuestionState();
    });

    try {
      final storage = QuestionBankStorage(file: file);
      final bank = await storage.load();

      // 页面已销毁，或又开始了新的加载：丢弃这次结果
      if (!mounted || token != _loadToken) return;

      // 一个题库只由一个插件处理；插件没装就提示，装了就走 WebView 宿主
      final String pluginId = bank.effectivePlugin;
      _pluginId = pluginId;
      if (pluginId != PluginManager.builtinId &&
          !await PluginManager.isInstalled(pluginId)) {
        if (!mounted || token != _loadToken) return;
        setState(() {
          _loading = false;
          _error = '这个题库需要插件「$pluginId」，请到 设置 → 插件管理 安装';
        });
        return;
      }

      final PluginManifest? manifest = pluginId == PluginManager.builtinId
          ? null
          : await _findPluginManifest(pluginId);

      // 断点续练：题目 id 顺序完全一致才恢复，避免判分结果对错题
      final List<String> questionIds = bank.questions
          .map((Question question) => question.id)
          .toList();
      final PracticeProgress? progress = await PracticeProgress.load(
        file,
        questionIds,
      );

      if (!mounted || token != _loadToken) return;

      // 旧 persistence 的待保存内容已经在方法开头 flush 过了
      _persistence?.dispose();
      final persistence = PracticePersistence(file: file)..bind(storage);

      setState(() {
        _persistence = persistence;
        _questions = bank;
        _pluginManifest = manifest;
        _loading = false;
        // 上次没回拷成功时，完成页也能看到提示
        _syncMessage = storage.pendingSyncWarning;
        // 用断点恢复本次练习；没有断点就从头开始
        _controller.loadBank(bank, progress);
      });

      final String? warning = storage.pendingSyncWarning;
      final List<String> notices = <String>[
        ?warning,
        if (progress != null) '已恢复上次练习进度（第 ${progress.index + 1} 题）',
      ];
      final String? notice = notices.isEmpty ? null : notices.join('\n');

      if (notice != null) {
        // 答题页把提示显示成 SnackBar，避免用户以为记录丢了
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          ScaffoldMessenger.maybeOf(context)
              ?.showSnackBar(SnackBar(content: Text(notice)));
        });
      }
    } catch (error) {
      if (!mounted || token != _loadToken) return;
      setState(() {
        _loading = false;
        _error = '读取题库失败：$error';
      });
    }
  }

  /// 读取插件清单；失败时不影响练习页加载。
  Future<PluginManifest?> _findPluginManifest(String id) async {
    try {
      return await PluginManager.find(id);
    } catch (error) {
      debugPrint('读取插件清单失败：$id $error');
      return null;
    }
  }

  /// 重置“当前题”相关的临时状态，进入下一题时调用。
  void _resetQuestionState() {
    _selected.clear();
    _answerController.clear();
    _answerImages.clear();
    _showAnswer = false;
    _answered = false;
    _wasCorrect = false;
    _grading = false;
    _aiFallback = false;
    _aiScore = null;
    _aiAnalysisLoading = false;
    _aiAnalysis = null;
    _aiAnalysisError = null;
  }

  /// 记录一次作答：更新内存统计，并立刻写一次工作副本。
  void _recordAnswer(bool correct) {
    if (_answered) return; // 防止同一题重复计数

    final bank = _questions;
    if (bank == null || _index >= bank.questions.length) return;

    final question = bank.questions[_index];
    question.stats.attemptCount += 1; // 答了一次
    if (!correct) {
      question.stats.wrongCount += 1; // 只有答错才累计错误数
    }

    // 错题本里的题：答对 -1、答错 +1，减到 0 即完成（题目保留，不移出）
    final int? mistakeScore = question.mistakeScore;
    if (mistakeScore != null) {
      question.mistakeScore = mistakeScore + (correct ? -1 : 1);
    }

    setState(() {
      // 状态机记录判分结果，供「上一题」恢复和断点续练使用
      _controller.record(correct);
    });

    // 每答完一题只排队一次防抖保存，不再每题整份写盘
    _schedulePersist();
    unawaited(_saveProgress());
  }

  /// 把主观题作答交给 AI 判分：得分 >= 6 判为答对。
  ///
  /// 文字答案和拍照上传的作答图片至少有一项即可提交；
  /// 判分失败（网络、Key 失效等）时提示并退回自判，保证这题还能继续做。
  Future<void> _submitWithAi(Question question) async {
    final String answer = _answerController.text.trim();
    if ((answer.isEmpty && _answerImages.isEmpty) || _grading) return;

    setState(() => _grading = true);
    try {
      final int score = await PracticeAiService.score(
        question,
        answer: answer,
        answerImages: _answerImages,
        sourceDirectoryRef: _storage?.sourceDirectoryRef,
      );
      if (!mounted) return;

      _aiScore = score; // 先记分，_recordAnswer 的 setState 会一并刷新
      _recordAnswer(score >= 6);
    } on DsApiException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('AI 判分失败：${error.message}')));
      setState(() => _aiFallback = true); // 本题退回自判
    } finally {
      if (mounted) setState(() => _grading = false);
    }
  }

  /// 选择作答图片：Android 支持拍照或相册，桌面端直接打开文件选择器。
  Future<void> _pickAnswerImage() async {
    if (_answerImages.length >= AnswerImagePicker.maxImages) {
      _toast('最多上传 ${AnswerImagePicker.maxImages} 张作答图片');
      return;
    }

    final bool isAndroid = defaultTargetPlatform == TargetPlatform.android;
    final AnswerImageSource? source = isAndroid
        ? await showModalBottomSheet<AnswerImageSource>(
            context: context,
            builder: (BuildContext sheetContext) => SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  ListTile(
                    leading: const Icon(Icons.photo_camera_outlined),
                    title: const Text('拍照'),
                    onTap: () =>
                        Navigator.pop(sheetContext, AnswerImageSource.camera),
                  ),
                  ListTile(
                    leading: const Icon(Icons.photo_library_outlined),
                    title: const Text('从相册选择'),
                    onTap: () =>
                        Navigator.pop(sheetContext, AnswerImageSource.gallery),
                  ),
                ],
              ),
            ),
          )
        : AnswerImageSource.gallery;

    if (!mounted || source == null) return;

    try {
      final Uint8List? bytes = await AnswerImagePicker.pick(source);
      if (!mounted || bytes == null) return;

      final int totalBytes =
          _answerImages.fold<int>(
            0,
            (int sum, Uint8List existing) => sum + existing.length,
          ) +
          bytes.length;
      if (totalBytes > AnswerImagePicker.maxTotalBytes) {
        _toast('作答图片合计超过 10 MB，请删掉几张再试');
        return;
      }
      setState(() => _answerImages.add(bytes));
    } on AnswerImageException catch (error) {
      if (mounted) _toast(error.message);
    } catch (error) {
      if (mounted) _toast('选择图片失败：$error');
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  /// 请求 AI 解析当前题目：把题干、选项（主观题为空）、正确答案，
  /// 以及主观题的作答文字/作答图片（有图则带图）发给模型。
  ///
  /// 结果存在页面最下方的「AI 解析」框里；失败时在同一个框里显示原因并可重试。
  Future<void> _requestAiAnalysis(Question question) async {
    if (_aiAnalysisLoading) return;

    setState(() {
      _aiAnalysisLoading = true;
      _aiAnalysisError = null;
    });

    try {
      final String text = await PracticeAiService.explain(
        question,
        correctAnswer: _answerText(question),
        // 主观题把作答也带上，AI 才能指出错在哪；判分后输入区收起但内容还在
        userAnswer: question.isFillBlank ? _answerController.text : null,
        answerImages: question.isFillBlank
            ? _answerImages
            : const <Uint8List>[],
        sourceDirectoryRef: _storage?.sourceDirectoryRef,
      );

      if (!mounted) return;
      setState(() => _aiAnalysis = text);
    } on DsApiException catch (error) {
      if (!mounted) return;
      setState(() => _aiAnalysisError = error.message);
    } finally {
      if (mounted) setState(() => _aiAnalysisLoading = false);
    }
  }

  /// 安排一次防抖保存（防抖和串行写盘在 PracticePersistence 里）。
  void _schedulePersist() {
    final bank = _questions;
    if (bank != null) _persistence?.scheduleSave(bank);
  }

  /// 立即把待保存内容写进工作副本；没有待保存任务时直接返回。
  Future<void> _flushPersist() => _persistence?.flush() ?? Future<void>.value();

  /// 把工作副本回拷到题库文件夹。
  Future<bool> _syncBack() =>
      _persistence?.syncBack() ?? Future<bool>.value(false);

  /// 保存断点：题目 id 顺序、当前题号、本次计数和已答结果。
  ///
  /// 整套做完后由调用方清除；题库还没加载完时什么都不做。
  Future<void> _saveProgress() async {
    final QuestionBank? bank = _questions;
    if (bank == null || _finished) return;

    await _persistence?.saveProgress(
      bank: bank,
      index: _index,
      answeredCount: _answeredCount,
      correctCount: _correctCount,
      answers: _answeredStates,
    );
  }

  /// 选择题提交：选中的集合必须和正确答案完全一致。
  void _submitChoice() {
    final bank = _questions;
    if (bank == null) return;

    final question = bank.questions[_index];
    final correct =
        question.correctAnswers.length == _selected.length &&
        question.correctAnswers.every(_selected.contains);

    _recordAnswer(correct);
  }

  /// 下一题；已经是最后一题就进入完成页并回拷源文件。
  void _next() {
    final bank = _questions;
    if (bank == null) return;

    if (_index + 1 >= bank.questions.length) {
      setState(() => _finished = true);
      // 整套做完：删掉断点，下次进入从头开始
      final QuestionBankFile? file = widget.bank;
      if (file != null) unawaited(PracticeProgress.clear(file));
      unawaited(_finishAndSync());
      return;
    }

    _goTo(_index + 1);
  }

  /// 上一题；已经是第一题就不动（按钮此时禁用）。
  void _previous() {
    if (_index <= 0) return;
    _goTo(_index - 1);
  }

  /// 跳到指定题。
  ///
  /// 这题如果已经答过，恢复当时的判分结果和选择，让它变成只读的回顾状态：
  /// 不再出现提交按钮，因此不会重复计数、也不会改动原题库的统计。
  void _goTo(int index) {
    final answered = _answeredStates[index];

    setState(() {
      _resetQuestionState(); // 清掉 AI 解析、输入框等临时状态
      _controller.goTo(index);

      if (answered != null) {
        _showAnswer = true; // 填空/解释：直接显示参考答案
      }
    });

    // 切题即记下断点，下次打开能停在这一题
    unawaited(_saveProgress());
  }

  /// 整套题做完后的回拷，并把结果显示在完成页。
  Future<void> _finishAndSync() async {
    if (!mounted) return;
    setState(() => _syncMessage = '正在同步到题库文件夹…');

    // 先落盘最后一次答题，再回拷；storage 的串行队列保证先后顺序
    await _flushPersist();
    final ok = await _syncBack();
    if (!mounted) return;

    setState(() {
      _syncMessage = ok ? '已同步到题库文件夹' : '同步失败，请检查题库文件夹的写入权限';
    });
  }

  /// 重新从第一题开始；统计不重置，因为题目统计是累计值。
  void _restart() {
    final QuestionBankFile? file = widget.bank;
    if (file != null) unawaited(PracticeProgress.clear(file));

    setState(() {
      _controller.restart();
      _syncMessage = null;
      _resetQuestionState();
    });
  }

  @override
  Widget build(BuildContext context) {
    final bank = widget.bank;

    // 标题用题库展示名（子目录题库带「子目录/」前缀），方便确认当前是哪一份。
    return Scaffold(
      appBar: AppBar(title: Text(bank?.displayName ?? '练习')),
      body: _buildBody(bank),
    );
  }

  /// 按“未选题库 / 加载中 / 加载失败 / 空题库 / 已完成 / 答题中”分支展示。
  Widget _buildBody(QuestionBankFile? file) {
    if (file == null) {
      return const Center(child: Text('请先在“管理”里选择一个题库'));
    }
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
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => _loadBank(file),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    final bank = _questions;
    if (bank == null || bank.questions.isEmpty) {
      return const Center(child: Text('这个题库里没有题目'));
    }
    if (_finished) {
      return _buildFinished(bank);
    }

    return _buildQuestion(bank, bank.questions[_index]);
  }

  /// 单题界面：standard 和第三方插件都走 WebView 宿主；测试/关闭运行时走原生视图。
  Widget _buildQuestion(QuestionBank bank, Question question) {
    if (PluginRuntime.enabled) {
      return PluginPracticeView(
        pluginId: _pluginId,
        question: question,
        index: _index,
        total: bank.questions.length,
        answered: _answered,
        wasCorrect: _wasCorrect,
        selected: _selected,
        mistakeScore: question.mistakeScore,
        isMistakeDone: question.isMistakeDone,
        aiEnabled: !_aiFallback && (AppConfig.dsApiKey ?? '').trim().isNotEmpty,
        correctAnswerText: _answerText(question),
        sourceDirectoryRef: _storage?.sourceDirectoryRef,
        bankFile: widget.bank,
        plugin: _pluginManifest,
        onSubmit: (bool correct, Set<String> selected) {
          setState(() {
            _selected
              ..clear()
              ..addAll(selected);
          });
          _recordAnswer(correct);
        },
        onNext: _next,
        onPrevious: _previous,
        onRequestAiExplain: (String answer) async {
          if ((AppConfig.dsApiKey ?? '').trim().isEmpty) {
            return '未配置 DeepSeek API Key，请先到设置里填写。';
          }
          try {
            return await PracticeAiService.explain(
              question,
              correctAnswer: _answerText(question),
              userAnswer: answer,
              answerImages: const <Uint8List>[],
              sourceDirectoryRef: _storage?.sourceDirectoryRef,
            );
          } on DsApiException catch (error) {
            return 'AI 解析失败：${error.message}';
          } catch (error) {
            return 'AI 解析失败：$error';
          }
        },
        onRequestAiScore: (String answer, List<Uint8List> images) async {
          if ((AppConfig.dsApiKey ?? '').trim().isEmpty) {
            throw DsApiException('未配置 DeepSeek API Key');
          }
          return PracticeAiService.score(
            question,
            answer: answer,
            answerImages: images,
            sourceDirectoryRef: _storage?.sourceDirectoryRef,
          );
        },
        onRequestAiComplete: (String prompt, List<Uint8List> images) async {
          if ((AppConfig.dsApiKey ?? '').trim().isEmpty) {
            throw DsApiException('未配置 DeepSeek API Key');
          }
          return PracticeAiService.complete(prompt: prompt, images: images);
        },
        onUpdatePluginData: (Map<String, dynamic> data) async {
          final QuestionBank? bank = _questions;
          if (bank == null || _index >= bank.questions.length) return;
          final Question current = bank.questions[_index];
          setState(() {
            current.pluginData = Map<String, dynamic>.from(data);
          });
          _schedulePersist();
          await _flushPersist();
        },
      );
    }

    return PracticeQuestionView(
      question: question,
      index: _index,
      total: bank.questions.length,
      selected: _selected,
      answered: _answered,
      wasCorrect: _wasCorrect,
      showAnswer: _showAnswer,
      grading: _grading,
      aiEnabled: !_aiFallback && (AppConfig.dsApiKey ?? '').trim().isNotEmpty,
      aiScore: _aiScore,
      aiAnalysisLoading: _aiAnalysisLoading,
      aiAnalysis: _aiAnalysis,
      aiAnalysisError: _aiAnalysisError,
      answerController: _answerController,
      answerImages: _answerImages,
      correctAnswerText: _answerText(question),
      sourceDirectoryRef: _storage?.sourceDirectoryRef,
      onSelectOption: _selectOption,
      onSubmitChoice: _submitChoice,
      onSubmitAi: () => _submitWithAi(question),
      onShowAnswer: () => setState(() => _showAnswer = true),
      onSelfJudge: _recordAnswer,
      onAnswerChanged: () => setState(() {}),
      onPickImage: _pickAnswerImage,
      onRemoveImage: (int index) =>
          setState(() => _answerImages.removeAt(index)),
      onRequestAiAnalysis: () => _requestAiAnalysis(question),
      onNext: _next,
      onPrevious: _previous,
    );
  }

  /// 选择题点选：多选切换，单选/判断只留一个。
  void _selectOption(String key) {
    final bank = _questions;
    if (bank == null) return;
    final question = bank.questions[_index];

    setState(() {
      if (question.isMultipleChoice) {
        if (!_selected.add(key)) _selected.remove(key);
      } else {
        _selected
          ..clear()
          ..add(key);
      }
    });
  }

  /// 把正确答案转成适合展示的文字：选择题带上选项内容。
  String _answerText(Question question) {
    if (question.isFillBlank) {
      return question.correctAnswers.join(' / ');
    }

    final texts = question.options
        .where(
          (QuestionOption option) =>
              question.correctAnswers.contains(option.key),
        )
        .map((QuestionOption option) => '${option.key}. ${option.text}')
        .toList();

    return texts.isEmpty
        ? question.correctAnswers.join(' / ')
        : texts.join(' / ');
  }

  /// 完成页：本次成绩 + 回拷状态 + 再练一遍。
  Widget _buildFinished(QuestionBank bank) {
    final colorScheme = Theme.of(context).colorScheme;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.check_circle_outline,
              size: 72,
              color: colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text(
              '练习完成',
              style: Theme.of(context).textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            Text(
              '共 ${bank.questions.length} 题，本次作答 $_answeredCount 题，答对 $_correctCount 题',
              textAlign: TextAlign.center,
            ),
            if (_syncMessage != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                _syncMessage!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _restart,
                child: const Text('再练一遍'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
