(function () {
  'use strict';

  var pendingCalls = {};
  var callSeq = 0;

  var state = {
    ctx: null,
    lastId: '',
    config: { mode: 'auto', threshold: 6, fontSize: 13 },
    answers: { blanks: [], text: '', choice: [] },
    result: null,
    showRef: false,
    aiLoading: false,
    explain: '',
    explainLoading: false
  };

  /* ---------------- 宿主桥 ---------------- */

  function postToHost(message) {
    var json = JSON.stringify(message);
    if (window.TBankChannel &&
        typeof window.TBankChannel.postMessage === 'function') {
      window.TBankChannel.postMessage(json);
      return;
    }
    if (window.chrome && window.chrome.webview &&
        typeof window.chrome.webview.postMessage === 'function') {
      window.chrome.webview.postMessage(json);
      return;
    }
    throw new Error('宿主桥未连接');
  }

  function hostCall(name, args) {
    return new Promise(function (resolve, reject) {
      var id = String(++callSeq);
      pendingCalls[id] = { resolve: resolve, reject: reject };
      try {
        postToHost({ id: id, name: name, args: args || {} });
      } catch (error) {
        delete pendingCalls[id];
        reject(error);
      }
    });
  }

  window.__tbankResolve = function (id, result) {
    var pending = pendingCalls[id];
    if (!pending) return;
    delete pendingCalls[id];
    pending.resolve(result);
  };

  window.__tbankReject = function (id, message) {
    var pending = pendingCalls[id];
    if (!pending) return;
    delete pendingCalls[id];
    pending.reject(new Error(message || '插件调用失败'));
  };

  function toast(message) {
    hostCall('tbankToast', { message: message }).catch(function () {});
  }

  /* ---------------- 主题与配置 ---------------- */

  function applyTheme() {
    var theme = state.ctx && state.ctx.theme;
    if (!theme) return;
    var style = document.documentElement.style;
    var map = {
      background: '--bg',
      surface: '--card',
      text: '--fg',
      muted: '--muted',
      line: '--line',
      primary: '--primary',
      primarySoft: '--primary-soft',
      ok: '--ok',
      okSoft: '--ok-soft',
      bad: '--bad',
      badSoft: '--bad-soft'
    };
    Object.keys(map).forEach(function (key) {
      if (theme[key]) style.setProperty(map[key], theme[key]);
    });
  }

  function applyFontSize() {
    var size = Number(state.config.fontSize) || 13;
    if (size < 11) size = 11;
    if (size > 20) size = 20;
    document.documentElement.style.setProperty('--code-size', size + 'px');
  }

  function loadConfig() {
    return hostCall('tbankConfigGet', {}).then(function (config) {
      if (config && typeof config === 'object') {
        if (config.mode === 'mobile' || config.mode === 'ide' ||
            config.mode === 'auto') {
          state.config.mode = config.mode;
        }
        var threshold = Number(config.threshold);
        if (threshold >= 0 && threshold <= 10) {
          state.config.threshold = threshold;
        }
        var size = Number(config.fontSize);
        if (size >= 11 && size <= 20) state.config.fontSize = size;
      }
      applyFontSize();
    }).catch(function () {});
  }

  /* ---------------- 状态 ---------------- */

  function isIdeMode() {
    if (state.config.mode === 'ide') return true;
    if (state.config.mode === 'mobile') return false;
    return window.innerWidth >= 760;
  }

  function currentQuestion() {
    return state.ctx && state.ctx.question ? state.ctx.question : null;
  }

  function pluginData() {
    var q = currentQuestion();
    return (q && q.pluginData) || {};
  }

  function answeredNow() {
    return !!(state.ctx && state.ctx.answered);
  }

  function resetAnswers() {
    var q = currentQuestion();
    if (!q) return;
    var pd = pluginData();
    var selected = (state.ctx.selected || []).slice();

    state.result = null;
    state.showRef = false;
    state.explain = '';
    state.explainLoading = false;

    if (q.type === 'cpp_fill') {
      var count = CppCore.blankCount(pd.code || '');
      var blanks = [];
      for (var i = 0; i < count; i++) blanks.push(selected[i] || '');
      state.answers.blanks = blanks;
      state.answers.text = '';
      state.answers.choice = [];
    } else if (q.type === 'cpp_ide') {
      state.answers.text = selected.length ? String(selected[0]) :
        String(pd.starterCode || '');
      state.answers.blanks = [];
      state.answers.choice = [];
    } else {
      if ((q.options || []).length) {
        state.answers.choice = selected.slice();
        state.answers.text = '';
      } else {
        state.answers.text = selected.length ? String(selected[0]) : '';
        state.answers.choice = [];
      }
      state.answers.blanks = [];
    }
  }

  /* ---------------- 渲染 ---------------- */

  function escHtml(value) {
    return CppCore.esc(value);
  }

  function typeLabel(type) {
    if (type === 'cpp_read') return '代码阅读';
    if (type === 'cpp_fill') return '代码填空';
    if (type === 'cpp_ide') return '编程题';
    return 'C/C++';
  }

  function codeLanguage() {
    var lang = pluginData().language;
    return String(lang || 'cpp').toLowerCase() === 'c' ? 'c' : 'cpp';
  }

  function renderPlainCode(code) {
    var lines = String(code || '').split('\n');
    var html = '';
    for (var i = 0; i < lines.length; i++) {
      html += '<div class="code-line">' +
        '<span class="code-no">' + (i + 1) + '</span>' +
        '<span class="code-src">' + CppCore.highlight(lines[i], codeLanguage()) +
        '</span></div>';
    }
    return html;
  }

  function renderBlanksCode(code, disabled) {
    var lines = String(code || '').split('\n');
    var html = '';
    var blankIndex = 0;
    for (var i = 0; i < lines.length; i++) {
      var parts = lines[i].split(/(_{4,})/);
      var lineHtml = '';
      for (var j = 0; j < parts.length; j++) {
        var part = parts[j];
        if (/^_{4,}$/.test(part)) {
          var value = state.answers.blanks[blankIndex] || '';
          lineHtml += '<span class="blank-wrap"><input class="blank-input"' +
            ' data-bi="' + blankIndex + '"' +
            ' value="' + escHtml(value) + '"' +
            (disabled ? ' disabled' : '') +
            ' autocomplete="off" spellcheck="false"></span>';
          blankIndex++;
        } else if (part) {
          lineHtml += CppCore.highlight(part, codeLanguage());
        }
      }
      html += '<div class="code-line">' +
        '<span class="code-no">' + (i + 1) + '</span>' +
        '<span class="code-src">' + lineHtml + '</span></div>';
    }
    return html;
  }

  function renderCodeCard() {
    var q = currentQuestion();
    var pd = pluginData();
    var lang = codeLanguage().toUpperCase();

    if (q.type === 'cpp_fill') {
      var code = pd.code || '';
      if (!code) {
        return '<div class="card code-card"><div class="code-head">' +
          '<span class="code-lang">' + lang + '</span>' +
          '<span>缺少 pluginData.code</span></div></div>';
      }
      return '<div class="card code-card">' +
        '<div class="code-head"><span class="code-lang">' + lang +
        '</span><span>填空 · 共 ' + CppCore.blankCount(code) + ' 空</span></div>' +
        '<pre class="code-body">' + renderBlanksCode(code, answeredNow() ||
          !!state.result) + '</pre></div>';
    }

    if (q.type === 'cpp_read') {
      var readCode = pd.code || '';
      if (!readCode) return '';
      return '<div class="card code-card">' +
        '<div class="code-head"><span class="code-lang">' + lang +
        '</span><span>只读</span></div>' +
        '<pre class="code-body">' + renderPlainCode(readCode) + '</pre></div>';
    }

    return '';
  }

  function renderOptions() {
    var q = currentQuestion();
    var options = q.options || [];
    var selected = state.answers.choice;
    var correct = q.correctAnswers || [];
    var answered = answeredNow() || !!state.result;

    var html = '<div class="answer-title">选择答案</div><div class="options">';
    for (var i = 0; i < options.length; i++) {
      var option = options[i];
      var key = String(option.key);
      var isSel = selected.indexOf(key) >= 0;
      var cls = 'option';
      if (answered) {
        if (correct.indexOf(key) >= 0) cls += ' ok';
        else if (isSel) cls += ' bad';
      } else if (isSel) {
        cls += ' sel';
      }
      html += '<div class="' + cls + '" data-action="option" data-key="' +
        escHtml(key) + '">' +
        '<span class="option-key">' + escHtml(key) + '</span>' +
        '<span class="option-text">' + escHtml(option.text) + '</span></div>';
    }
    html += '</div>';
    return html;
  }

  function renderEditor() {
    var q = currentQuestion();
    var pd = pluginData();
    // 只有编程题在宽屏下给行号编辑器；阅读/简答始终用普通文本框。
    var wide = q.type === 'cpp_ide' && isIdeMode();
    var disabled = answeredNow() || !!state.result;
    var code = String(state.answers.text || '');
    var value = escHtml(code);

    if (!wide) {
      return '<div class="answer-title">作答</div>' +
        '<textarea class="text-area" data-role="text" spellcheck="false"' +
        (disabled ? ' disabled' : '') +
        ' placeholder="' + (q.type === 'cpp_ide' ? '在这里写 C/C++ 代码' : '在这里写答案') +
        '">' + value + '</textarea>' +
        '<div class="editor-note">' +
        (q.type === 'cpp_ide'
          ? '手机模式：纯文本编辑，宽屏设备会自动切换为带行号的编辑器。'
          : '用文字作答，提交后由 AI 按大一课程标准判分。') +
        '</div>';
    }

    return '<div class="answer-title">作答 · ' +
      codeLanguage().toUpperCase() + '</div>' +
      '<div class="editor">' +
      '<div class="editor-gutter" data-role="gutter">' +
      gutterText(code.length ? code : '\n') + '</div>' +
      '<textarea class="editor-area" data-role="editor" spellcheck="false"' +
      ' wrap="off"' + (disabled ? ' disabled' : '') +
      ' placeholder="' + escHtml(pd.starterCode ? '' : '在这里写代码') + '">' +
      value + '</textarea></div>' +
      '<div class="editor-note">Tab 缩进 · Ctrl/⌘ + Enter 提交</div>';
  }

  function gutterText(code) {
    var lines = String(code).split('\n');
    if (!lines.length) lines = [''];
    return lines.map(function (_, i) { return i + 1; }).join('\n');
  }

  function renderAnswerArea() {
    var q = currentQuestion();
    if (q.type === 'cpp_read' && (q.options || []).length) return renderOptions();
    if (q.type === 'cpp_fill') {
      return '<div class="card"><div class="answer-title">作答</div>' +
        '<div class="editor-note">直接在上面的代码里填空，填完点「提交」。</div></div>';
    }
    return '<div class="card">' + renderEditor() + '</div>';
  }

  function referenceText() {
    var q = currentQuestion();
    var answers = q.correctAnswers || [];
    if (!answers.length) return '';
    if (q.type === 'cpp_read' && (q.options || []).length) {
      return answers.map(function (key) {
        var hit = (q.options || []).filter(function (o) {
          return String(o.key) === String(key);
        })[0];
        return hit ? (key + '. ' + hit.text) : key;
      }).join('\n');
    }
    if (q.type === 'cpp_fill') {
      return answers.map(function (text, i) {
        return '第 ' + (i + 1) + ' 空：' + text;
      }).join('\n');
    }
    return answers.join('\n\n');
  }

  function renderReference() {
    var text = referenceText();
    if (!text) return '';

    if (state.showRef) {
      var isCode = currentQuestion().type !== 'cpp_fill' &&
        text.indexOf('{') >= 0;
      var body = isCode
        ? '<pre class="code-body">' + renderPlainCode(text) + '</pre>'
        : '<div class="result-reason">' + escHtml(text) + '</div>';
      return '<div class="card"><div class="answer-title">参考答案</div>' +
        body + '</div>';
    }

    return '<div class="ref-toggle"><button class="btn small" ' +
      'data-action="show-ref">查看参考答案</button></div>';
  }

  function renderResult() {
    var r = state.result;
    var answered = answeredNow();

    if (state.aiLoading) {
      return '<div class="result"><div class="result-title">' +
        '<span class="spinner"></span>AI 正在判分…</div>' +
        '<div class="result-reason">按大一 C/C++ 课程标准评分，通常几秒。</div></div>';
    }

    if (!r && !answered) return '';

    if (r && r.pending) {
      return '<div class="result">' +
        '<div class="result-title">' + (r.error ? 'AI 判分失败' : '请对照参考答案自判') +
        '</div>' +
        (r.error ? '<div class="result-reason">' + escHtml(r.error) + '</div>' : '') +
        renderReference() +
        '<div class="actions" style="position:static;background:none;' +
        'border:0;padding:10px 0 0;backdrop-filter:none;">' +
        '<button class="btn primary" data-action="self-ok">答对了</button>' +
        '<button class="btn" data-action="self-bad">答错了</button>' +
        '</div></div>';
    }

    var correct = r ? r.correct : !!state.ctx.wasCorrect;
    var title = correct ? '答对了' : '答错了';

    if (r && typeof r.score === 'number') {
      title += ' · AI 评分 ' + r.score + '/10';
    }

    var html = '<div class="result ' + (correct ? 'ok' : 'bad') + '">' +
      '<div class="result-title">' + title + '</div>';

    if (r && r.reason) {
      html += '<div class="result-reason">' + escHtml(r.reason) + '</div>';
    }
    if (r && r.issues && r.issues.length) {
      html += '<ul class="issues">' + r.issues.map(function (issue) {
        return '<li>' + escHtml(issue) + '</li>';
      }).join('') + '</ul>';
    }
    html += renderReference();
    html += '</div>';
    return html;
  }

  function renderExplain() {
    var answered = answeredNow() || !!state.result;
    if (!answered) return '';

    if (state.explainLoading) {
      return '<div class="result"><div class="result-title">' +
        '<span class="spinner"></span>AI 正在解析…</div></div>';
    }

    if (state.explain) {
      return '<div class="card"><div class="answer-title">AI 解析</div>' +
        '<div class="ai-box" style="border:0;padding-top:0;color:var(--fg)">' +
        escHtml(state.explain) + '</div></div>';
    }

    return '<div class="ref-toggle"><button class="btn small" ' +
      'data-action="explain">AI 解析</button></div>';
  }

  function renderActions() {
    var answered = answeredNow();
    var canSubmit = !answered && !state.result;

    var html = '<div class="actions">' +
      '<button class="btn ghost" data-action="prev">上一题</button>';

    if (canSubmit) {
      html += '<button class="btn primary" data-action="submit">提交</button>';
    } else {
      html += '<button class="btn primary" data-action="next">下一题</button>';
    }

    html += '</div>';
    return html;
  }

  function renderQuestionMeta() {
    var q = currentQuestion();
    var pd = pluginData();
    var chips = [];
    chips.push('<span class="chip">' + codeLanguage().toUpperCase() + '</span>');
    if (pd.tests && pd.tests.length) {
      chips.push('<span class="chip">' + pd.tests.length + ' 个测试点</span>');
    }
    if (q.stats) {
      chips.push('<span class="chip">已答 ' + (q.stats.attemptCount || 0) +
        ' 次 · 错 ' + (q.stats.wrongCount || 0) + ' 次</span>');
    }
    return '<div class="meta-row">' + chips.join('') + '</div>';
  }

  function render() {
    var app = document.getElementById('app');
    var q = currentQuestion();

    if (!q) {
      app.innerHTML = '<div class="loading">正在加载题目…</div>';
      return;
    }

    applyTheme();
    applyFontSize();

    var total = Math.max(1, state.ctx.total || 1);
    var index = Math.max(0, state.ctx.index || 0);
    var progress = Math.min(100, Math.round((index + 1) / total * 100));
    var pd = pluginData();

    var html = '<div class="topbar">' +
      '<span class="badge">' + escHtml(typeLabel(q.type)) + '</span>' +
      '<span class="pos">' + (index + 1) + ' / ' + total + '</span></div>' +
      '<div class="progress"><i style="width:' + progress + '%"></i></div>';

    html += '<div class="card"><div class="q-text">' + escHtml(q.question) +
      '</div>' + renderQuestionMeta() + '</div>';

    if (pd.hint) {
      html += '<div class="card"><div class="hint">' + escHtml(pd.hint) +
        '</div></div>';
    }

    if (q.type === 'cpp_ide' && pd.tests && pd.tests.length) {
      html += '<div class="card"><div class="answer-title">测试点</div>' +
        '<ol class="issues">' + pd.tests.map(function (t) {
          return '<li>' + escHtml(t) + '</li>';
        }).join('') + '</ol></div>';
    }

    html += renderCodeCard();
    html += renderAnswerArea();
    html += renderResult();
    html += renderExplain();
    html += renderActions();

    app.innerHTML = html;

    var editor = app.querySelector('[data-role="editor"]');
    if (editor) {
      editor.addEventListener('scroll', function () {
        var gutter = app.querySelector('[data-role="gutter"]');
        if (gutter) gutter.scrollTop = editor.scrollTop;
      });
      editor.addEventListener('input', function () {
        state.answers.text = editor.value;
        syncGutter(app, editor);
      });
    }
  }

  function syncGutter(app, editor) {
    var gutter = app.querySelector('[data-role="gutter"]');
    if (!gutter) return;
    gutter.textContent = gutterText(editor.value || '\n');
    gutter.scrollTop = editor.scrollTop;
  }

  /* ---------------- 交互 ---------------- */

  function updateAnswers(event) {
    var target = event.target;
    if (!target) return;

    if (target.classList.contains('blank-input')) {
      var bi = Number(target.getAttribute('data-bi'));
      state.answers.blanks[bi] = target.value;
      return;
    }

    if (target.getAttribute('data-role') === 'editor') {
      state.answers.text = target.value;
      var app = document.getElementById('app');
      syncGutter(app, target);
      return;
    }

    if (target.getAttribute('data-role') === 'text') {
      state.answers.text = target.value;
    }
  }

  function handleKeydown(event) {
    var target = event.target;

    if ((event.ctrlKey || event.metaKey) && event.key === 'Enter') {
      event.preventDefault();
      submit();
      return;
    }

    if (target && target.getAttribute('data-role') === 'editor' &&
        event.key === 'Tab') {
      event.preventDefault();
      var start = target.selectionStart;
      var end = target.selectionEnd;
      var value = target.value;
      if (event.shiftKey) {
        var before = value.slice(0, start);
        var lineStart = before.lastIndexOf('\n') + 1;
        var line = value.slice(lineStart, start);
        var trimmed = line.replace(/^ {1,4}|^\t/, '');
        if (trimmed !== line) {
          target.value = value.slice(0, lineStart) + trimmed +
            value.slice(start);
          target.selectionStart = target.selectionEnd =
            Math.max(lineStart, start - (line.length - trimmed.length));
          state.answers.text = target.value;
          syncGutter(document.getElementById('app'), target);
        }
      } else {
        target.value = value.slice(0, start) + '    ' + value.slice(end);
        target.selectionStart = target.selectionEnd = start + 4;
        state.answers.text = target.value;
        syncGutter(document.getElementById('app'), target);
      }
      return;
    }

    if (target && target.getAttribute('data-role') === 'editor' &&
        event.key === 'Enter') {
      var pos = target.selectionStart;
      var all = target.value;
      var lineStart = all.lastIndexOf('\n', pos - 1) + 1;
      var currentLine = all.slice(lineStart, pos);
      var indent = CppCore.indentOf(currentLine);
      var extra = /[{(]\s*$/.test(currentLine) ? '    ' : '';
      if (!indent && !extra) return;
      event.preventDefault();
      var insert = '\n' + indent + extra;
      target.value = all.slice(0, pos) + insert + all.slice(pos);
      target.selectionStart = target.selectionEnd = pos + insert.length;
      state.answers.text = target.value;
      syncGutter(document.getElementById('app'), target);
    }
  }

  function toggleChoice(key) {
    if (answeredNow() || state.result) return;
    var q = currentQuestion();
    var multiple = (q.correctAnswers || []).length > 1;
    var selected = state.answers.choice;

    if (multiple) {
      var at = selected.indexOf(key);
      if (at >= 0) selected.splice(at, 1);
      else selected.push(key);
    } else {
      state.answers.choice = [key];
    }
    render();
  }

  function selfJudge(correct) {
    var r = state.result;
    if (!r || !r.pending) return;
    finish(correct, r.selected || [], {
      source: 'manual',
      reason: correct ? '自判为正确' : '自判为错误'
    });
  }

  function finish(correct, selected, extra) {
    var payload = {
      correct: correct,
      selected: selected
    };
    Object.keys(extra || {}).forEach(function (key) {
      payload[key] = extra[key];
    });
    state.result = payload;
    state.aiLoading = false;
    hostCall('tbankSubmit', {
      correct: correct,
      selected: selected
    }).catch(function () {});
    render();
  }

  function submit() {
    var q = currentQuestion();
    if (!q) return;
    if (answeredNow() || state.result || state.aiLoading) return;

    if (q.type === 'cpp_read' && (q.options || []).length) {
      var choice = state.answers.choice.slice();
      if (!choice.length) {
        toast('先选一个答案');
        return;
      }
      var okChoice = CppCore.sameChoice(choice, q.correctAnswers || []);
      finish(okChoice, choice, { source: 'local' });
      return;
    }

    if (q.type === 'cpp_fill') {
      var blanks = state.answers.blanks.slice();
      var filled = blanks.filter(function (v) { return String(v).trim(); });
      if (!filled.length) {
        toast('先把空填上');
        return;
      }
      var okFill = CppCore.fillAllCorrect(blanks, q.correctAnswers || []);
      finish(okFill, blanks, { source: 'local' });
      return;
    }

    var answer = String(state.answers.text || '').trim();
    if (!answer) {
      toast('先写点东西再提交');
      return;
    }

    if (!state.ctx.aiEnabled) {
      state.result = { pending: true, selected: [answer], error: '' };
      render();
      return;
    }

    aiJudge(q, answer);
  }

  function aiJudge(q, answer) {
    state.aiLoading = true;
    render();

    var pd = pluginData();
    var prompt = CppCore.buildScorePrompt({
      question: q.question,
      tests: pd.tests || [],
      reference: (q.correctAnswers || []).join('\n\n'),
      answer: answer
    });

    hostCall('tbankAiComplete', { prompt: prompt }).then(function (text) {
      var parsed = CppCore.parseScore(text);
      if (parsed.score === null) {
        throw new Error('AI 返回里没有可识别的分数');
      }
      var threshold = Number(state.config.threshold);
      if (isNaN(threshold)) threshold = 6;
      finish(parsed.score >= threshold, [answer], {
        source: 'ai',
        score: parsed.score,
        reason: parsed.reason,
        issues: parsed.issues
      });
    }).catch(function (error) {
      state.aiLoading = false;
      state.result = {
        pending: true,
        selected: [answer],
        error: 'AI 判分没成功：' + (error && error.message ? error.message : error)
      };
      render();
    });
  }

  function explain() {
    var q = currentQuestion();
    if (!q || state.explainLoading) return;
    if (!state.ctx.aiEnabled) {
      toast('没有配置 DeepSeek 密钥，无法使用 AI 解析');
      return;
    }

    var pd = pluginData();
    var answer = state.answers.text ||
      (state.answers.blanks.join(' / ')) ||
      state.answers.choice.join(', ');

    var prompt = [
      '你是大学 C/C++ 程序设计课的助教。请用中文讲清下面这道题。',
      '',
      '【题目】',
      q.question,
      '',
      pd.code ? ('【代码】\n' + pd.code) : '',
      pd.starterCode ? ('【起始代码】\n' + pd.starterCode) : '',
      (q.correctAnswers || []).length
        ? ('【参考答案】\n' + (q.correctAnswers || []).join('\n'))
        : '',
      '【学生作答】',
      answer || '（未作答）',
      '',
      '要求：',
      '1. 先给结论，再分步骤讲；',
      '2. 代码题要指出每步执行结果或关键语句作用；',
      '3. 指出学生答案的对错点与典型错误；',
      '4. 控制在 400 字以内，数学式用 $...$。'
    ].filter(Boolean).join('\n');

    state.explainLoading = true;
    render();

    hostCall('tbankAiComplete', { prompt: prompt }).then(function (text) {
      state.explainLoading = false;
      state.explain = String(text || '').trim();
      render();
    }).catch(function (error) {
      state.explainLoading = false;
      state.explain = '解析失败：' +
        (error && error.message ? error.message : error);
      render();
    });
  }

  function handleClick(event) {
    var option = event.target.closest('[data-action="option"]');
    if (option) {
      toggleChoice(option.getAttribute('data-key'));
      return;
    }

    var action = event.target.closest('[data-action]');
    if (!action) return;

    var name = action.getAttribute('data-action');
    if (name === 'submit') submit();
    else if (name === 'next') hostCall('tbankNext', {}).catch(function () {});
    else if (name === 'prev') hostCall('tbankPrevious', {}).catch(function () {});
    else if (name === 'show-ref') { state.showRef = true; render(); }
    else if (name === 'self-ok') selfJudge(true);
    else if (name === 'self-bad') selfJudge(false);
    else if (name === 'explain') explain();
  }

  /* ---------------- 宿主入口 ---------------- */

  window.__tbankReceive = function (next) {
    if (!next || !next.question) {
      state.ctx = next;
      render();
      return;
    }

    var id = String(next.question.id || '');
    if (id !== state.lastId) {
      state.lastId = id;
      state.ctx = next;
      resetAnswers();
      applyTheme();
      render();
      return;
    }

    if (Array.isArray(next.selected) && !next.answered &&
        !state.result) {
      state.answers.choice = next.selected.slice();
    }

    state.ctx = next;
    applyTheme();
    render();
  };

  function boot() {
    var app = document.getElementById('app');
    if (app) {
      app.addEventListener('input', updateAnswers);
      app.addEventListener('click', handleClick);
      app.addEventListener('keydown', handleKeydown);
    }
    loadConfig().then(render);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot);
  } else {
    boot();
  }
})();
