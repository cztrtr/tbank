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
import '../services/study_history.dart';
import 'practice_ai_service.dart';
import 'practice_controller.dart';
import 'practice_finished_view.dart';
import 'practice_host.dart';
import 'practice_persistence.dart';

/// 练习页：加载题库、逐题作答、更新统计并回写文件。
///
/// 页面状态分三类：
/// - 加载态：_loading / _error / _questions；
/// - 当前题：_index / _selected / _showAnswer / _answered / _wasCorrect；
/// - 整份进度：_finished / _answeredCount / _correctCount / _syncMessage。
class PracticePage extends StatefulWidget {
  const PracticePage({
    super.key,
    this.bank,
    this.active = true,
    this.hostBuilder = defaultPracticeHostBuilder,
  });

  /// 从题库管理页选中的题库文件；null 表示还没选。
  final QuestionBankFile? bank;

  /// 当前练习 tab 是否可见；切到其它 tab 时通知插件暂停计时器/渲染。
  final bool active;

  /// 题型渲染器；默认是 WebView 插件宿主，测试可注入 fake host。
  final PracticeHostBuilder hostBuilder;

  @override
  State<PracticePage> createState() => _PracticePageState();
}

class _PracticePageState extends State<PracticePage>
    with WidgetsBindingObserver {
  /// 保存/回拷/断点都交给它，页面不再自己管计时器和串行队列。
  PracticePersistence? _persistence;

  QuestionBankStorage? get _storage => _persistence?.storage;
  QuestionBank? _questions; // 已读进内存的题库

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

  bool _aiFallback = false; // AI 判分不可用时，本题退回自判

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
    QuestionBankStorage.sourceChangedNotifier.addListener(_onBankSourceChanged);

    final bank = widget.bank;
    if (bank != null) {
      unawaited(_loadBank(bank));
    }
  }

  /// 题目编辑器改了当前题库：重新加载，避免继续在旧题干/旧解析上作答。
  void _onBankSourceChanged() {
    final String? changedUri = QuestionBankStorage.sourceChangedNotifier.value;
    final QuestionBankFile? bank = widget.bank;
    if (!mounted || changedUri == null || bank == null) return;
    if (changedUri != bank.uri) return;
    unawaited(_loadBank(bank));
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
    QuestionBankStorage.sourceChangedNotifier.removeListener(
      _onBankSourceChanged,
    );

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
      if (pluginId != PluginManager.builtinId &&
          !await PluginManager.isInstalled(pluginId)) {
        if (!mounted || token != _loadToken) return;
        setState(() {
          _loading = false;
          _error = '这个题库需要插件「$pluginId」，请到 设置 → 插件管理 安装';
        });
        return;
      }

      // 第三方插件读取 manifest，用于 v2 capabilities 校验；内置 standard
      // 直接信任（也避免在 widget 测试里为它同步 7 MB 资源）。
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
    _answered = false;
    _wasCorrect = false;
    _aiFallback = false;
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

    // 学习历史按天独立记录，不依赖题库文件是否成功回写。
    unawaited(StudyHistory.recordAnswer(correct: correct));

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
    setState(() {
      _resetQuestionState();
      _controller.goTo(index);
    });
    // answered 由 controller.goTo 恢复，供 host 显示只读回顾状态。

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
    final bool isLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;

    // 标题用题库展示名（子目录题库带「子目录/」前缀），方便确认当前是哪一份。
    return Scaffold(
      // 横屏把顶部空间留给题目/手写区。
      appBar: isLandscape
          ? null
          : AppBar(title: Text(bank?.displayName ?? '练习')),
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
      return PracticeFinishedView(
        total: bank.questions.length,
        answeredCount: _answeredCount,
        correctCount: _correctCount,
        syncMessage: _syncMessage,
        onRestart: _restart,
      );
    }

    return _buildQuestion(bank, bank.questions[_index]);
  }

  /// 单题界面：统一交给 [PracticeHostBuilder]（默认是 WebView 插件宿主）。
  Widget _buildQuestion(QuestionBank bank, Question question) {
    final PracticeHostData data = PracticeHostData(
      bankFile: widget.bank,
      plugin: _pluginManifest,
      question: question,
      index: _index,
      total: bank.questions.length,
      answered: _answered,
      wasCorrect: _wasCorrect,
      active: widget.active,
      aiEnabled: !_aiFallback && AppConfig.hasDsApiKey,
      isMistakeDone: question.isMistakeDone,
      selected: _selected,
      mistakeScore: question.mistakeScore,
      correctAnswerText: _answerText(question),
      sourceDirectoryRef:
          _storage?.sourceDirectoryRef ?? widget.bank?.directoryRef,
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
        if (!AppConfig.hasDsApiKey) {
          return '未配置 DeepSeek API Key，请先到设置里填写。';
        }
        try {
          return await PracticeAiService.explain(
            question,
            correctAnswer: _answerText(question),
            userAnswer: answer,
            answerImages: const <Uint8List>[],
            sourceDirectoryRef:
                _storage?.sourceDirectoryRef ?? widget.bank?.directoryRef,
          );
        } on DsApiException catch (error) {
          return 'AI 解析失败：${error.message}';
        } catch (error) {
          return 'AI 解析失败：$error';
        }
      },
      onRequestAiScore: (String answer, List<Uint8List> images) async {
        if (!AppConfig.hasDsApiKey) {
          throw DsApiException('未配置 DeepSeek API Key');
        }
        return PracticeAiService.score(
          question,
          answer: answer,
          answerImages: images,
          sourceDirectoryRef:
              _storage?.sourceDirectoryRef ?? widget.bank?.directoryRef,
        );
      },
      onRequestAiComplete: (String prompt, List<Uint8List> images) async {
        if (!AppConfig.hasDsApiKey) {
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
        // 走 400ms 防抖；插件频繁回写（手写/草稿）时不再每次都整份落盘。
        _schedulePersist();
      },
    );

    return widget.hostBuilder(context, data);
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
}
