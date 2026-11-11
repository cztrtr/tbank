(function (root, factory) {
  if (typeof module === 'object' && module.exports) {
    module.exports = factory();
  } else {
    root.CppCore = factory();
  }
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  var C_KEYWORDS = [
    'auto', 'break', 'case', 'char', 'const', 'continue', 'default', 'do',
    'double', 'else', 'enum', 'extern', 'float', 'for', 'goto', 'if',
    'inline', 'int', 'long', 'register', 'restrict', 'return', 'short',
    'signed', 'sizeof', 'static', 'struct', 'switch', 'typedef', 'union',
    'unsigned', 'void', 'volatile', 'while', 'NULL', 'true', 'false'
  ];

  var CPP_KEYWORDS = C_KEYWORDS.concat([
    'alignas', 'alignof', 'bool', 'catch', 'class', 'constexpr', 'decltype',
    'delete', 'explicit', 'export', 'friend', 'mutable', 'namespace', 'new',
    'noexcept', 'nullptr', 'operator', 'private', 'protected', 'public',
    'template', 'this', 'throw', 'try', 'typename', 'using', 'virtual',
    'wchar_t'
  ]);

  function esc(value) {
    return String(value == null ? '' : value)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }

  function keywordSet(language) {
    var list = String(language || '').toLowerCase() === 'c'
      ? C_KEYWORDS
      : CPP_KEYWORDS;
    var set = Object.create(null);
    for (var i = 0; i < list.length; i++) set[list[i]] = true;
    return set;
  }

  // 单行内做词法着色：注释、字符串、数字、关键字。
  function highlightLine(line, keywords) {
    var re = /(\/\/[^\n]*|\/\*[\s\S]*?\*\/|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|\b[A-Za-z_]\w*\b|\b\d+(?:\.\d+)?\b)/g;
    var out = '';
    var last = 0;
    var match;

    while ((match = re.exec(line)) !== null) {
      out += esc(line.slice(last, match.index));
      var token = match[0];
      var cls = '';

      if (token.slice(0, 2) === '//' || token.slice(0, 2) === '/*') {
        cls = 'tok-com';
      } else if (token.charAt(0) === '"' || token.charAt(0) === "'") {
        cls = 'tok-str';
      } else if (/^\d/.test(token)) {
        cls = 'tok-num';
      } else if (keywords[token]) {
        cls = 'tok-kw';
      }

      out += cls
        ? '<span class="' + cls + '">' + esc(token) + '</span>'
        : esc(token);
      last = match.index + token.length;
    }

    out += esc(line.slice(last));
    return out;
  }

  function highlight(code, language) {
    var keywords = keywordSet(language);
    var lines = String(code == null ? '' : code).split('\n');
    var out = [];

    for (var i = 0; i < lines.length; i++) {
      var line = lines[i];
      if (/^\s*#/.test(line)) {
        out.push('<span class="tok-pre">' + esc(line) + '</span>');
      } else {
        out.push(highlightLine(line, keywords));
      }
    }

    return out.join('\n');
  }

  // 代码里用连续四个及以上下划线表示空位。
  function blankCount(code) {
    var matches = String(code == null ? '' : code).match(/_{4,}/g);
    return matches ? matches.length : 0;
  }

  function splitByBlanks(code) {
    return String(code == null ? '' : code).split(/(_{4,})/);
  }

  function normalizeAnswer(value) {
    return String(value == null ? '' : value)
      .replace(/\r\n/g, '\n')
      .replace(/\s+/g, ' ')
      .trim();
  }

  // 选择题比较：集合完全一致才算对。
  function sameChoice(selected, correct) {
    var a = (selected || []).map(String).sort();
    var b = (correct || []).map(String).sort();
    if (a.length !== b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] !== b[i]) return false;
    }
    return true;
  }

  // 填空比较：逐个空位归一化后比较。
  function fillAllCorrect(answers, correct) {
    var expected = correct || [];
    if (!expected.length || answers.length !== expected.length) return false;
    for (var i = 0; i < expected.length; i++) {
      if (normalizeAnswer(answers[i]) !== normalizeAnswer(expected[i])) {
        return false;
      }
    }
    return true;
  }

  var RUBRIC = [
    '按中国大学《C/C++ 程序设计》大一入门课标准评分，不要用工程级要求苛求。',
    '1. 语法与编译：存在明显语法/编译错误，最多 4 分。',
    '2. 逻辑与结果：核心逻辑正确给 7~8 分；完全正确且处理边界给 9~10 分。',
    '3. 边界与格式：漏判 0 或负数、数组越界、死循环、输出格式不符，各扣 1~2 分。',
    '4. 只写伪代码或思路没有可运行代码：最多 6 分。',
    '5. 空白或与题目无关：0 分。'
  ].join('\n');

  function buildScorePrompt(input) {
    input = input || {};
    var sections = [];

    sections.push('你是一名大学 C/C++ 程序设计课程的助教，正在批改大一学生的上机题。');
    sections.push('【评分标准】\n' + RUBRIC);
    sections.push('【题目】\n' + (input.question || '（略）'));

    if (input.tests && input.tests.length) {
      sections.push('【测试点】\n' + input.tests.map(function (item, i) {
        return (i + 1) + '. ' + item;
      }).join('\n'));
    }

    if (input.reference) {
      sections.push('【参考答案】\n' + input.reference);
    }

    sections.push('【学生作答】\n' + (input.answer || '（空白）'));
    sections.push(
      '只输出一个 JSON 对象，不要 Markdown 围栏，不要多余文字：\n' +
      '{"score": 0到10的整数, "reason": "一句话结论", "issues": ["扣分点1", "扣分点2"]}'
    );

    return sections.join('\n\n');
  }

  function clampScore(value) {
    var n = Number(value);
    if (isNaN(n)) return null;
    if (n < 0) n = 0;
    if (n > 10) n = 10;
    return Math.round(n);
  }

  function parseScore(text) {
    var raw = String(text == null ? '' : text).trim();
    var score = null;
    var reason = '';
    var issues = [];

    // 先尝试整体 JSON
    var jsonText = raw;
    var fence = raw.match(/```(?:json)?\s*([\s\S]*?)```/i);
    if (fence) jsonText = fence[1].trim();

    var start = jsonText.indexOf('{');
    var end = jsonText.lastIndexOf('}');
    if (start >= 0 && end > start) {
      try {
        var obj = JSON.parse(jsonText.slice(start, end + 1));
        score = clampScore(obj.score);
        reason = obj.reason == null ? '' : String(obj.reason);
        if (Array.isArray(obj.issues)) {
          issues = obj.issues.map(String).slice(0, 6);
        }
      } catch (_) {
        score = null;
      }
    }

    if (score === null) {
      var m = raw.match(/"score"\s*:\s*(-?\d+(?:\.\d+)?)/i);
      if (m) score = clampScore(m[1]);
    }
    if (score === null) {
      var m2 = raw.match(/(-?\d+(?:\.\d+)?)\s*\/\s*10/);
      if (m2) score = clampScore(m2[1]);
    }
    if (score === null) {
      var m3 = raw.match(/(-?\d+(?:\.\d+)?)\s*分/);
      if (m3) score = clampScore(m3[1]);
    }
    if (score === null) {
      var m4 = raw.match(/^\s*(-?\d+(?:\.\d+)?)\s*$/);
      if (m4) score = clampScore(m4[1]);
    }

    if (!reason) {
      var cleaned = raw
        .replace(/```(?:json)?/gi, '')
        .replace(/[{}"]/g, ' ')
        .replace(/\s+/g, ' ')
        .trim();
      reason = cleaned.slice(0, 120);
    }

    return { score: score, reason: reason, issues: issues, raw: raw };
  }

  function mergeLines(code) {
    return String(code == null ? '' : code).replace(/\r\n/g, '\n');
  }

  function indentOf(line) {
    var m = String(line || '').match(/^[ \t]*/);
    return m ? m[0] : '';
  }

  return {
    esc: esc,
    highlight: highlight,
    blankCount: blankCount,
    splitByBlanks: splitByBlanks,
    normalizeAnswer: normalizeAnswer,
    sameChoice: sameChoice,
    fillAllCorrect: fillAllCorrect,
    buildScorePrompt: buildScorePrompt,
    parseScore: parseScore,
    clampScore: clampScore,
    mergeLines: mergeLines,
    indentOf: indentOf
  };
});
