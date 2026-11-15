import 'dart:convert';

/// 一次生成过程中的质量检查结果。
class QuestionQualityReport {
  int parsed = 0;
  int accepted = 0;
  int duplicates = 0;
  int invalid = 0;
  final List<String> notes = <String>[];

  int get removed => duplicates + invalid;
  bool get hasIssues => removed > 0;

  void addInvalid(String reason) {
    invalid += 1;
    if (notes.length < 6) notes.add(reason);
  }

  String get summary {
    if (!hasIssues) return '质量检查通过';
    final StringBuffer buffer = StringBuffer('质量检查：');
    if (duplicates > 0) buffer.write('去重 $duplicates 道');
    if (invalid > 0) {
      if (duplicates > 0) buffer.write('，');
      buffer.write('过滤 $invalid 道');
    }
    return buffer.toString();
  }
}

/// 本地出题质量闸门：不改写模型内容，只拒收明显不合格的题。
class QuestionQuality {
  QuestionQuality._();

  static const Set<String> _standardChoiceTypes = <String>{
    'single_choice',
    'multiple_choice',
    'true_false',
  };

  /// 清理并去重一批题。
  ///
  /// [seen] 在整轮生成中复用，用于跨批次去重；[report] 累计统计。
  static List<Map<String, dynamic>> sanitizeBatch({
    required List<Map<String, dynamic>> questions,
    required Set<String> seen,
    required QuestionQualityReport report,
  }) {
    final List<Map<String, dynamic>> accepted = <Map<String, dynamic>>[];
    for (final Map<String, dynamic> raw in questions) {
      report.parsed += 1;
      final Map<String, dynamic>? clean = _clean(raw, report);
      if (clean == null) continue;

      final String fingerprint = _fingerprint(clean);
      if (seen.contains(fingerprint)) {
        report.duplicates += 1;
        report.notes.add('重复题：${_short(clean['question'])}');
        continue;
      }
      seen.add(fingerprint);
      accepted.add(clean);
    }
    report.accepted += accepted.length;
    return accepted;
  }

  static Map<String, dynamic>? _clean(
    Map<String, dynamic> raw,
    QuestionQualityReport report,
  ) {
    final String type = raw['type']?.toString().trim() ?? '';
    final String question = _compact(raw['question']);
    if (question.length < 2) {
      report.addInvalid('题干为空');
      return null;
    }

    final String analysis = _compact(raw['analysis']);
    if (!_meaningfulAnalysis(analysis)) {
      report.addInvalid('解析为空：${_short(question)}');
      return null;
    }

    final List<Map<String, dynamic>> options = <Map<String, dynamic>>[];
    final dynamic rawOptions = raw['options'];
    if (rawOptions is List) {
      for (final dynamic item in rawOptions) {
        if (item is! Map) continue;
        final String key = item['key']?.toString().trim() ?? '';
        final String text = _compact(item['text']);
        if (key.isEmpty || text.isEmpty) continue;
        options.add(<String, dynamic>{'key': key, 'text': text});
      }
    }

    final dynamic rawAnswer = raw['correctAnswer'];
    final List<String> answers = rawAnswer is List
        ? rawAnswer
              .whereType<String>()
              .map((String answer) => answer.trim())
              .where((String answer) => answer.isNotEmpty)
              .toList()
        : rawAnswer is String && rawAnswer.trim().isNotEmpty
        ? <String>[rawAnswer.trim()]
        : <String>[];

    if (answers.isEmpty) {
      report.addInvalid('答案为空：${_short(question)}');
      return null;
    }

    if (_standardChoiceTypes.contains(type)) {
      if (options.length < 2 || options.length > 6) {
        report.addInvalid('选项数量异常：${_short(question)}');
        return null;
      }
      if (type == 'multiple_choice' && answers.length < 2) {
        report.addInvalid('多选题答案不足两个：${_short(question)}');
        return null;
      }
      if (type != 'multiple_choice' && answers.length != 1) {
        report.addInvalid('单选题答案数量异常：${_short(question)}');
        return null;
      }
      final Set<String> keys = options
          .map((Map<String, dynamic> option) => option['key'] as String)
          .toSet();
      if (answers.any((String answer) => !keys.contains(answer))) {
        report.addInvalid('答案不在选项中：${_short(question)}');
        return null;
      }
      final Set<String> optionTexts = <String>{};
      for (final Map<String, dynamic> option in options) {
        final String text = _normalize(option['text'] as String);
        if (!optionTexts.add(text)) {
          report.addInvalid('选项内容重复：${_short(question)}');
          return null;
        }
      }
    }

    final Map<String, dynamic> clean = Map<String, dynamic>.from(raw);
    clean['question'] = question;
    clean['analysis'] = analysis;
    clean['options'] = options;
    clean['correctAnswer'] = answers;
    return clean;
  }

  static bool _meaningfulAnalysis(String analysis) {
    final String normalized = _normalize(analysis);
    if (normalized.length < 4) return false;
    const Set<String> placeholders = <String>{
      '暂无解析',
      '无解析',
      '解析',
      '略',
      '略。',
      '见答案',
      '略述',
    };
    return !placeholders.contains(normalized);
  }

  static String _fingerprint(Map<String, dynamic> question) {
    final String type = question['type']?.toString() ?? '';
    return '$type|${_normalize(question['question']?.toString() ?? '')}';
  }

  static String _normalize(String value) {
    return value.toLowerCase().replaceAll(
      RegExp(r'[\s，。；：！？、,.!?;:()（）\[\]【】“”‘’\-—_/\\]+'),
      '',
    );
  }

  static String _compact(dynamic value) {
    return (value?.toString() ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static String _short(dynamic value) {
    final String text = _compact(value);
    return text.length <= 24 ? text : '${text.substring(0, 24)}…';
  }

  /// 给调用方一个可读的报告 JSON，目前用于调试/后续扩展。
  static String toJson(QuestionQualityReport report) {
    return jsonEncode(<String, dynamic>{
      'parsed': report.parsed,
      'accepted': report.accepted,
      'duplicates': report.duplicates,
      'invalid': report.invalid,
      'notes': report.notes,
    });
  }
}
