import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';

/// 支持 LaTeX 数学式的文本组件。
///
/// 题库里的题干、选项、解析、AI 输出都可以内嵌 LaTeX 公式，约定：
/// - 行内公式：`$...$` 或 `\(...\)`
/// - 独立公式：`$$...$$` 或 `\[...\]`
///
/// 普通文本与行内公式混排在同一段落里；独立公式单独占一行。
/// 公式解析失败时退化成原始 LaTeX 源码显示，不影响继续阅读。
class MathText extends StatelessWidget {
  const MathText(
    this.text, {
    super.key,
    this.style,
    this.textAlign = TextAlign.start,
    this.selectable = false,
  });

  /// 原始文本，可能包含 LaTeX 公式。
  final String text;

  /// 普通文本样式；公式会沿用其中的字号与颜色。
  final TextStyle? style;

  /// 文本对齐方式（目前仅用于纯文本模式）。
  final TextAlign textAlign;

  /// 纯文本模式下是否使用 SelectableText（可复制）。
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    final TextStyle textStyle = style ?? DefaultTextStyle.of(context).style;
    final List<_Segment> segments = _parse(text);
    final bool hasMath = segments.any((_Segment s) => s.latex != null);

    // 没有公式：保持原来的纯文本渲染（可保留选择/复制能力）
    if (!hasMath) {
      return selectable
          ? SelectableText(text, style: textStyle, textAlign: textAlign)
          : Text(text, style: textStyle, textAlign: textAlign);
    }

    // 有公式：行内片段用 RichText 混排，独立公式单独成行
    final List<Widget> children = <Widget>[];
    List<_Segment> inline = <_Segment>[];

    void flushInline() {
      if (inline.isEmpty) return;
      children.add(_buildInline(context, inline, textStyle));
      inline = <_Segment>[];
    }

    for (final _Segment segment in segments) {
      if (segment.latex != null && segment.block) {
        flushInline();
        children.add(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: _buildMath(segment.latex!, textStyle),
          ),
        );
      } else {
        inline.add(segment);
      }
    }
    flushInline();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }

  /// 把一个行内片段序列渲染成一个段落：文本 + 行内公式交替。
  Widget _buildInline(
    BuildContext context,
    List<_Segment> segments,
    TextStyle textStyle,
  ) {
    return RichText(
      textAlign: textAlign,
      text: TextSpan(
        style: textStyle,
        children: <InlineSpan>[
          for (final _Segment segment in segments)
            if (segment.latex != null)
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: _buildMath(segment.latex!, textStyle),
              )
            else
              TextSpan(text: segment.text),
        ],
      ),
    );
  }

  /// 渲染一段 LaTeX；解析失败时退化为原始源码文本。
  Widget _buildMath(String latex, TextStyle textStyle) {
    return Math.tex(
      _cleanLatex(latex),
      textStyle: textStyle,
      onErrorFallback: (Object error) => Text(latex, style: textStyle),
    );
  }

  /// 渲染前的轻量清洗：去掉首尾空白，修掉多转义一层的双反斜杠。
  ///
  /// AI 生成的解析偶尔把 `\frac` 写成 `\\frac`（JSON 里多转义一次），
  /// 数学引擎会把它当成换行指令；这里只在双反斜杠后面紧跟命令名时合并。
  static String _cleanLatex(String latex) {
    final String trimmed = latex.trim();
    return trimmed.replaceAllMapped(
      RegExp(r'\\\\([a-zA-Z]+)'),
      (Match match) => _bareCommands.contains(match.group(1))
          ? '\\${match.group(1)}'
          : match.group(0)!,
    );
  }

  /// 单美元符号公式的启发式判断。
  ///
  /// 含中文的内容通常不是 LaTeX，多半是「$5 到 $10」这类价格写法；
  /// 但如果内容里有 `\text{...}` 或 `^` / `_` / `=` 之类的数学结构，
  /// 仍然按公式处理（AI 偶尔会把中文说明写进公式里）。
  static bool _looksLikeInlineMath(String content) {
    final String trimmed = content.trim();
    if (trimmed.isEmpty) return false;

    final bool hasMathStructure =
        trimmed.contains(RegExp(r'\\[a-zA-Z]+')) ||
        trimmed.contains(RegExp(r'[\^_=]'));

    if (trimmed.contains(RegExp(r'[\u4e00-\u9fa5]'))) {
      return hasMathStructure;
    }
    return true;
  }

  /// 常见 LaTeX 命令名。AI 漏写 `$` 时，只有这些命令才会被自动识别成公式，
  /// 避免把 `C:\Users` 这类普通文本误当成数学式。
  static const Set<String> _bareCommands = <String>{
    'frac',
    'dfrac',
    'tfrac',
    'binom',
    'sqrt',
    'sum',
    'prod',
    'int',
    'lim',
    'alpha',
    'beta',
    'gamma',
    'delta',
    'Delta',
    'epsilon',
    'varepsilon',
    'zeta',
    'eta',
    'theta',
    'Theta',
    'iota',
    'kappa',
    'lambda',
    'Lambda',
    'mu',
    'nu',
    'xi',
    'Xi',
    'pi',
    'Pi',
    'rho',
    'sigma',
    'Sigma',
    'tau',
    'upsilon',
    'phi',
    'Phi',
    'varphi',
    'chi',
    'psi',
    'Psi',
    'omega',
    'Omega',
    'infty',
    'partial',
    'nabla',
    'emptyset',
    'forall',
    'exists',
    'neg',
    'circ',
    'star',
    'ast',
    'oplus',
    'otimes',
    'perp',
    'parallel',
    'prime',
    'cdot',
    'times',
    'div',
    'pm',
    'mp',
    'le',
    'leq',
    'ge',
    'geq',
    'ne',
    'neq',
    'approx',
    'equiv',
    'sim',
    'simeq',
    'cong',
    'propto',
    'asymp',
    'doteq',
    'll',
    'gg',
    'in',
    'notin',
    'subset',
    'supset',
    'subseteq',
    'supseteq',
    'cup',
    'cap',
    'land',
    'lor',
    'to',
    'rightarrow',
    'leftarrow',
    'leftrightarrow',
    'Rightarrow',
    'Leftarrow',
    'mapsto',
    'angle',
    'triangle',
    'measuredangle',
    'because',
    'therefore',
    'sin',
    'cos',
    'tan',
    'cot',
    'sec',
    'csc',
    'arcsin',
    'arccos',
    'arctan',
    'sinh',
    'cosh',
    'tanh',
    'ln',
    'log',
    'lg',
    'exp',
    'max',
    'min',
    'sup',
    'inf',
    'det',
    'gcd',
    'deg',
    'vec',
    'overrightarrow',
    'overline',
    'underline',
    'hat',
    'widehat',
    'bar',
    'tilde',
    'dot',
    'ddot',
    'text',
    'mathrm',
    'mathbb',
    'mathcal',
    'mathbf',
    'mathit',
    'left',
    'right',
    'quad',
    'qquad',
    'displaystyle',
    'textstyle',
    'limits',
    'nolimits',
    'cdots',
    'ldots',
    'dots',
    'vdots',
    'ddots',
    'begin',
    'end',
    'degree',
  };

  static final RegExp _commandPattern = RegExp(r'\\([a-zA-Z]+)');
  static final RegExp _cjkPattern = RegExp(
    r'[\u4e00-\u9fa5\u3000-\u303f\uff01-\uff5e]',
  );

  /// 把 `\\frac` 这类多转义还原成 `\frac`（只处理白名单命令）。
  static String _collapseDoubleBackslash(String input) {
    return input.replaceAllMapped(RegExp(r'\\\\([a-zA-Z]+)'), (Match match) {
      return _bareCommands.contains(match.group(1))
          ? '\\${match.group(1)}'
          : match.group(0)!;
    });
  }

  /// 把普通文本里「没有被 $ 包裹」的 LaTeX 命令切成公式片段。
  static List<_Segment> _splitBareLatex(String text) {
    final List<_Segment> segments = <_Segment>[];
    final StringBuffer buffer = StringBuffer();

    void flush() {
      if (buffer.isEmpty) return;
      segments.add(_Segment.text(buffer.toString()));
      buffer.clear();
    }

    int i = 0;
    while (i < text.length) {
      if (text[i] == r'\') {
        final int end = _bareLatexEnd(text, i);
        if (end > i) {
          flush();
          segments.add(_Segment.math(text.substring(i, end)));
          i = end;
          continue;
        }
      }
      buffer.write(text[i]);
      i++;
    }
    flush();
    return segments;
  }

  /// 从 [start] 起算一段裸 LaTeX 的结束位置；不像公式时返回 [start]。
  ///
  /// 规则：
  /// - 必须以白名单里的命令开头；
  /// - 遇到中文 / 全角标点 / 换行 / `$` 就结束；
  /// - 花括号必须配平；
  /// - 公式外的英文单词（空格后跟字母）不吞进来。
  static int _bareLatexEnd(String text, int start) {
    final Match? match = _commandPattern.matchAsPrefix(text, start);
    if (match == null) return start;
    if (!_bareCommands.contains(match.group(1))) return start;

    int depth = 0;
    int i = start;
    int end = start;

    while (i < text.length) {
      final String ch = text[i];
      if (ch == r'$' || ch == '\n' || ch == '\r') break;
      if (_cjkPattern.hasMatch(ch)) break;

      if (ch == '{') {
        depth++;
      } else if (ch == '}') {
        if (depth == 0) break;
        depth--;
      } else if (ch == ' ' && depth == 0 && i + 1 < text.length) {
        // 「\frac{1}{2} where ...」里的英文单词不吞进公式
        if (RegExp(r'[A-Za-z]').hasMatch(text[i + 1])) break;
      }

      i++;
      end = i;
    }

    if (depth != 0) return start; // 括号没配平：不当作公式

    while (end > start && (text[end - 1] == ' ' || text[end - 1] == '\t')) {
      end--;
    }
    return end > start ? end : start;
  }

  // ---------------------------------------------------------------- 解析

  /// 把文本切成普通文本与公式片段。
  ///
  /// 分隔符按「先长后短」的顺序匹配，避免 `$$` 被当成两个 `$`。
  /// 分隔符不成对（例如正文里单独的美元符号）时按普通文本处理。
  static List<_Segment> _parse(String input) {
    final String source = _collapseDoubleBackslash(input);
    final List<_Segment> segments = <_Segment>[];
    final StringBuffer buffer = StringBuffer();

    void flushText() {
      if (buffer.isEmpty) return;
      final String text = buffer.toString();
      buffer.clear();
      // AI 生成的解析有时漏写 $，这里把裸 LaTeX 命令兜底识别成公式
      segments.addAll(_splitBareLatex(text));
    }

    int i = 0;
    while (i < source.length) {
      // 块级公式：$$...$$
      if (source.startsWith(r'$$', i)) {
        final int end = source.indexOf(r'$$', i + 2);
        if (end > i) {
          flushText();
          segments.add(
            _Segment.math(source.substring(i + 2, end), block: true),
          );
          i = end + 2;
          continue;
        }
      }

      // 块级公式：\[...\]
      if (source.startsWith(r'\[', i)) {
        final int end = source.indexOf(r'\]', i + 2);
        if (end > i) {
          flushText();
          segments.add(
            _Segment.math(source.substring(i + 2, end), block: true),
          );
          i = end + 2;
          continue;
        }
      }

      // 行内公式：\(...\)
      if (source.startsWith(r'\(', i)) {
        final int end = source.indexOf(r'\)', i + 2);
        if (end > i) {
          flushText();
          segments.add(_Segment.math(source.substring(i + 2, end)));
          i = end + 2;
          continue;
        }
      }

      // 行内公式：$...$
      if (source[i] == r'$' && !source.startsWith(r'$$', i)) {
        final int end = source.indexOf(r'$', i + 1);
        // 加一层启发式：内容含中文的不当公式，避免「$5 到 $10」这类
        // 价格写法被误解析（配对存在但不是 LaTeX）
        if (end > i && _looksLikeInlineMath(source.substring(i + 1, end))) {
          flushText();
          segments.add(_Segment.math(source.substring(i + 1, end)));
          i = end + 1;
          continue;
        }
      }

      buffer.write(source[i]);
      i++;
    }
    flushText();
    return segments;
  }
}

/// 文本片段：要么是普通文本，要么是 LaTeX 公式。
class _Segment {
  const _Segment.text(this.text) : latex = null, block = false;

  const _Segment.math(this.latex, {this.block = false}) : text = null;

  /// 普通文本内容（公式片段为 null）。
  final String? text;

  /// LaTeX 源码（文本片段为 null）。
  final String? latex;

  /// 是否是独立成行的块级公式。
  final bool block;
}
