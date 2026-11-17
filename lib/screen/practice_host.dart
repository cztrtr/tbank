import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/question_bank.dart';
import '../models/question_bank_file.dart';
import '../services/plugin_manager.dart';
import 'plugin_practice_view.dart';

/// 练习页交给「题型渲染器」的全部数据与回调。
///
/// 生产环境使用 [defaultPracticeHostBuilder]（WebView 插件宿主）；
/// widget 测试可以注入一个轻量 fake host，不需要真实 WebView。
class PracticeHostData {
  const PracticeHostData({
    required this.bankFile,
    required this.plugin,
    required this.question,
    required this.index,
    required this.total,
    required this.answered,
    required this.wasCorrect,
    required this.active,
    required this.aiEnabled,
    required this.isMistakeDone,
    required this.selected,
    required this.mistakeScore,
    required this.correctAnswerText,
    required this.sourceDirectoryRef,
    required this.onSubmit,
    required this.onNext,
    required this.onPrevious,
    required this.onRequestAiExplain,
    required this.onRequestAiScore,
    required this.onRequestAiComplete,
    required this.onUpdatePluginData,
  });

  final QuestionBankFile? bankFile;
  final PluginManifest? plugin;
  final Question question;
  final int index;
  final int total;
  final bool answered;
  final bool wasCorrect;
  final bool active;
  final bool aiEnabled;
  final bool isMistakeDone;
  final Set<String> selected;
  final int? mistakeScore;
  final String correctAnswerText;
  final String? sourceDirectoryRef;

  final void Function(bool correct, Set<String> selected) onSubmit;
  final VoidCallback onNext;
  final VoidCallback onPrevious;
  final Future<String> Function(String answer) onRequestAiExplain;
  final Future<int> Function(String answer, List<Uint8List> images)
  onRequestAiScore;
  final Future<String> Function(String prompt, List<Uint8List> images)
  onRequestAiComplete;
  final Future<void> Function(Map<String, dynamic> pluginData)
  onUpdatePluginData;
}

typedef PracticeHostBuilder = Widget Function(
  BuildContext context,
  PracticeHostData data,
);

/// 默认渲染器：交给插件 WebView 宿主。
Widget defaultPracticeHostBuilder(BuildContext context, PracticeHostData data) {
  return PluginPracticeView(
    pluginId: data.plugin?.id ?? PluginManager.builtinId,
    question: data.question,
    index: data.index,
    total: data.total,
    answered: data.answered,
    wasCorrect: data.wasCorrect,
    selected: data.selected,
    mistakeScore: data.mistakeScore,
    isMistakeDone: data.isMistakeDone,
    aiEnabled: data.aiEnabled,
    correctAnswerText: data.correctAnswerText,
    sourceDirectoryRef: data.sourceDirectoryRef,
    bankFile: data.bankFile,
    plugin: data.plugin,
    active: data.active,
    onSubmit: data.onSubmit,
    onNext: data.onNext,
    onPrevious: data.onPrevious,
    onRequestAiExplain: data.onRequestAiExplain,
    onRequestAiScore: data.onRequestAiScore,
    onRequestAiComplete: data.onRequestAiComplete,
    onUpdatePluginData: data.onUpdatePluginData,
  );
}
