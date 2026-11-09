(function () {
  'use strict';

  var ctx = null;
  var selected = new Set();
  var answerText = '';
  var answerImages = [];
  var aiText = '';
  var aiLoading = false;
  var aiScoring = false;
  var aiScore = null;
  var aiError = '';
  var showAnswer = false;
  var lastQuestionId = '';
  var pendingCalls = {};
  var callSeq = 0;

  function esc(value) {
    return String(value == null ? '' : value)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }

  function fmt(value) {
    return esc(value).replace(/\n/g, '<br>');
  }

  function typeLabel(type) {
    switch (type) {
      case 'single_choice': return '单选';
      case 'multiple_choice': return '多选';
      case 'true_false': return '判断';
      default: return '填空/简答';
    }
  }

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

  function applyTheme() {
    if (!ctx || !ctx.theme) return;
    var style = document.documentElement.style;
    var theme = ctx.theme;
    if (theme.background) style.setProperty('--bg', theme.background);
    if (theme.surface) style.setProperty('--card', theme.surface);
    if (theme.text) style.setProperty('--fg', theme.text);
    if (theme.muted) style.setProperty('--muted', theme.muted);
    if (theme.line) style.setProperty('--line', theme.line);
    if (theme.primary) style.setProperty('--primary', theme.primary);
    if (theme.primarySoft) style.setProperty('--primary-soft', theme.primarySoft);
    if (theme.ok) style.setProperty('--ok', theme.ok);
    if (theme.okSoft) style.setProperty('--ok-soft', theme.okSoft);
    if (theme.bad) style.setProperty('--bad', theme.bad);
    if (theme.badSoft) style.setProperty('--bad-soft', theme.badSoft);
  }

  window.__tbankReceive = function (next) {
    if (!next || !next.question) {
      ctx = next;
      render();
      return;
    }

    var id = String(next.question.id || '');
    if (id !== lastQuestionId) {
      selected = new Set(next.selected || []);
      answerText = '';
      answerImages = [];
      aiText = '';
      aiScoring = false;
      aiScore = null;
      aiError = '';
      showAnswer = false;
      lastQuestionId = id;
    } else if (Array.isArray(next.selected)) {
      selected = new Set(next.selected);
    }

    ctx = next;
    if (next.answered) showAnswer = true;
    applyTheme();
    render();
  };

  function render() {
    var app = document.getElementById('app');
    if (!ctx || !ctx.question) {
      app.innerHTML = '<div class="loading">正在加载题目…</div>';
      return;
    }

    var q = ctx.question;
    var answered = !!ctx.answered;
    var isFill = q.type === 'fill_blank';
    var options = Array.isArray(q.options) ? q.options : [];
    var correct = new Set(q.correctAnswers || []);
    var total = Math.max(1, ctx.total || 1);
    var progress = Math.round(((ctx.index || 0) + 1) / total * 100);

    var html = '';
    html += '<div class="meta-row"><span>第 ' + ((ctx.index || 0) + 1) +
      ' / ' + total + ' 题</span><span class="badge">' +
      typeLabel(q.type) + '</span></div>';
    html += '<div class="progress"><i style="width:' + progress + '%"></i></div>';
    html += '<div class="stats">本题已作答 ' +
      ((q.stats && q.stats.attemptCount) || 0) + ' 次 · 答错 ' +
      ((q.stats && q.stats.wrongCount) || 0) + ' 次</div>';
    html += '<div class="question">' + fmt(q.question) + '</div>';
    if (q.imageDataUrl) {
      html += '<img class="q-image" src="' + esc(q.imageDataUrl) + '" alt="">';
    }

    if (!isFill) {
      html += '<div class="options">';
      options.forEach(function (option) {
        var cls = 'option';
        if (answered) {
          if (correct.has(option.key)) cls += ' correct';
          else if (selected.has(option.key)) cls += ' wrong';
          cls += ' disabled';
        } else if (selected.has(option.key)) {
          cls += ' selected';
        }
        html += '<div class="' + cls + '" data-key="' + esc(option.key) + '">' +
          '<div class="key">' + esc(option.key) + '</div>' +
          '<div>' + fmt(option.text) + '</div></div>';
      });
      html += '</div>';
    } else if (!answered && !showAnswer) {
      html += '<textarea class="answer-box" id="answer" placeholder="在这里输入你的答案">' +
        esc(answerText) + '</textarea>';
      if (answerImages.length) {
        html += '<div class="thumbs">';
        answerImages.forEach(function (src, index) {
          html += '<div class="thumb"><img src="' + esc(src) + '" alt="">' +
            '<button type="button" data-remove-image="' + index + '">×</button></div>';
        });
        html += '</div>';
      }
    }

    // 操作按钮始终紧贴作答区下方；判分、解析、AI 全部放到按钮之后。
    if (answered) {
      html += '<div class="row">' +
        '<button class="outline" data-action="prev"' +
        (ctx.index <= 0 ? ' disabled' : '') + '>上一题</button>' +
        '<button class="primary" data-action="next">' +
        ((ctx.index || 0) + 1 >= total ? '完成练习' : '下一题') + '</button></div>';
    } else if (!isFill) {
      html += '<div class="row">' +
        '<button class="outline" data-action="prev"' +
        (ctx.index <= 0 ? ' disabled' : '') + '>上一题</button>' +
        '<button class="primary" data-action="submit"' +
        (selected.size ? '' : ' disabled') + '>提交答案</button></div>';
    } else if (showAnswer) {
      html += '<div class="row">' +
        '<button class="outline" data-action="prev"' +
        (ctx.index <= 0 ? ' disabled' : '') + '>上一题</button>' +
        '<button class="outline" data-action="wrong">答错了</button>' +
        '<button class="primary" data-action="right">答对了</button></div>';
    } else {
      html += '<div class="row">' +
        '<button class="outline" data-action="prev"' +
        (ctx.index <= 0 ? ' disabled' : '') + '>上一题</button>' +
        '<button class="outline" data-action="show">展示答案</button></div>';
      html += '<div class="row">' +
        '<button class="outline" data-action="pick-image">拍照 / 选图</button>';
      if (ctx.aiEnabled) {
        html += '<button class="primary" data-action="ai-submit"' +
          (aiScoring ? ' disabled' : '') + '>' +
          (aiScoring ? 'AI 判分中…' : '提交（AI 判分）') + '</button>';
      }
      html += '</div>';
      if (aiError) {
        html += '<div class="hint" style="color:var(--bad)">' + fmt(aiError) + '</div>';
      }
      html += '<div class="hint">' +
        (ctx.aiEnabled
          ? '提交后由 AI 判分；也可以先展示答案自判。'
          : '未配置 AI，可展示答案后自判。') + '</div>';
    }

    if (answered) {
      html += '<div class="card ' + (ctx.wasCorrect ? 'ok' : 'bad') + '">' +
        '<div class="card-title">' + (ctx.wasCorrect ? '回答正确' : '回答错误') + '</div>' +
        '<div class="line">' + (isFill ? '参考答案：' : '正确答案：') +
        fmt(ctx.correctAnswerText || '') + '</div>' +
        (aiScore !== null
          ? '<div class="muted">AI 评分：' + aiScore + ' / 10</div>'
          : '') +
        (ctx.mistakeScore != null
          ? '<div class="muted">错题本：' + (ctx.isMistakeDone
            ? '已完成' : '还需答对 ' + ctx.mistakeScore + ' 次') + '</div>'
          : '') +
        '</div>';
      if (q.analysis) {
        html += '<div class="card analysis"><div class="card-title">解析</div>' +
          '<div class="line">' + fmt(q.analysis) + '</div></div>';
      }
      html += '<div class="row"><button class="outline" data-action="ai">AI 解析</button></div>';
      if (aiLoading) {
        html += '<div class="card"><div class="muted">正在生成解析…</div></div>';
      } else if (aiText) {
        html += '<div class="card"><div class="card-title">AI 解析</div>' +
          '<div class="line">' + fmt(aiText) + '</div></div>';
      }
    } else if (isFill && showAnswer) {
      html += '<div class="card"><div class="card-title">参考答案</div>' +
        '<div class="line">' + fmt(ctx.correctAnswerText || '') + '</div></div>';
      if (q.analysis) {
        html += '<div class="card analysis"><div class="card-title">解析</div>' +
          '<div class="line">' + fmt(q.analysis) + '</div></div>';
      }
    }

    app.innerHTML = html;
    bind();
    renderMath(0);
  }

  function renderMath(attempt) {
    var app = document.getElementById('app');
    if (!app) return;
    if (!window.renderMathInElement) {
      if (attempt < 20) {
        setTimeout(function () { renderMath(attempt + 1); }, 150);
      }
      return;
    }
    try {
      window.renderMathInElement(app, {
        delimiters: [
          { left: '$$', right: '$$', display: true },
          { left: '$', right: '$', display: false },
          { left: '\\(', right: '\\)', display: false },
          { left: '\\[', right: '\\]', display: true }
        ],
        throwOnError: false,
        strict: false,
        errorCallback: function (message) {
          console.warn('KaTeX 渲染警告：' + message);
        }
      });
      fitDisplayMath();
    } catch (error) {
      // 公式渲染失败时保留原文，不影响作答
    }
  }

  /**
   * 让超宽的独立公式按卡片宽度等比缩小。
   *
   * KaTeX 的 display math 默认不换行，长推导会横向溢出并被裁掉；
   * 这里量一次实际宽度，放不下就 scale；缩到下限仍超宽时交给 CSS 横向滚动。
   */
  function fitDisplayMath() {
    window.requestAnimationFrame(function () {
      var displays = document.querySelectorAll('.katex-display');
      displays.forEach(function (display) {
        var katex = display.querySelector('.katex');
        if (!katex) return;

        katex.style.transform = '';
        katex.style.transformOrigin = 'left top';
        display.style.height = '';
        display.style.overflowX = '';
        display.style.overflowY = '';
        display.style.textAlign = '';

        var available = display.clientWidth;
        var width = katex.scrollWidth;
        if (!available || !width || width <= available + 1) return;

        var scale = Math.max(0.55, available / width);
        display.style.textAlign = 'left';
        katex.style.transform = 'scale(' + scale + ')';
        display.style.height = (katex.offsetHeight * scale) + 'px';
        display.style.overflowX = scale <= 0.56 ? 'auto' : 'hidden';
        display.style.overflowY = 'hidden';
      });
    });
  }

  function bind() {
    document.querySelectorAll('.option').forEach(function (element) {
      element.addEventListener('click', function () {
        if (!ctx || ctx.answered) return;
        var key = element.getAttribute('data-key');
        if (ctx.question.type === 'multiple_choice') {
          if (selected.has(key)) selected.delete(key);
          else selected.add(key);
        } else {
          selected.clear();
          selected.add(key);
        }
        render();
      });
    });

    document.querySelectorAll('[data-action]').forEach(function (element) {
      element.addEventListener('click', function () {
        if (!ctx) return;
        var action = element.getAttribute('data-action');
        if (action === 'submit') {
          submitChoice();
        } else if (action === 'next') {
          hostCall('tbankNext');
        } else if (action === 'prev') {
          hostCall('tbankPrevious');
        } else if (action === 'show') {
          var textarea = document.getElementById('answer');
          answerText = textarea ? textarea.value : answerText;
          showAnswer = true;
          render();
        } else if (action === 'right') {
          hostCall('tbankSubmit', { correct: true, selected: [], answer: answerText });
        } else if (action === 'wrong') {
          hostCall('tbankSubmit', { correct: false, selected: [], answer: answerText });
        } else if (action === 'ai') {
          requestAi();
        } else if (action === 'ai-submit') {
          submitFillAi();
        } else if (action === 'pick-image') {
          pickImage();
        }
      });
    });

    var textarea = document.getElementById('answer');
    if (textarea) {
      textarea.addEventListener('input', function () {
        answerText = textarea.value;
      });
    }

    document.querySelectorAll('[data-remove-image]').forEach(function (element) {
      element.addEventListener('click', function () {
        var index = Number(element.getAttribute('data-remove-image'));
        if (index >= 0 && index < answerImages.length) {
          answerImages.splice(index, 1);
          render();
        }
      });
    });
  }

  function submitChoice() {
    var correctSet = new Set(ctx.question.correctAnswers || []);
    var ok = selected.size === correctSet.size &&
      Array.from(selected).every(function (key) { return correctSet.has(key); });
    hostCall('tbankSubmit', { correct: ok, selected: Array.from(selected) });
  }

  async function submitFillAi() {
    if (aiScoring) return;
    var textarea = document.getElementById('answer');
    answerText = textarea ? textarea.value : answerText;
    if (!answerText.trim() && answerImages.length === 0) {
      aiError = '请先输入答案或选择作答图片';
      render();
      return;
    }

    aiScoring = true;
    aiError = '';
    render();
    try {
      var score = await hostCall('tbankAiScore', {
        answer: answerText,
        images: answerImages
      });
      aiScoring = false;
      if (typeof score === 'number') {
        aiScore = score;
        await hostCall('tbankSubmit', {
          correct: score >= 6,
          selected: [],
          answer: answerText
        });
      } else {
        aiError = score && score.error ? score.error : 'AI 判分失败';
        render();
      }
    } catch (error) {
      aiScoring = false;
      aiError = 'AI 判分失败：' +
        (error && error.message ? error.message : error);
      render();
    }
  }

  async function pickImage() {
    if (answerImages.length >= 4) {
      aiError = '最多上传 4 张作答图片';
      render();
      return;
    }
    try {
      var result = await hostCall('tbankPickImage', { source: 'gallery' });
      if (result && result.dataUrl) {
        answerImages.push(result.dataUrl);
        aiError = '';
        render();
      } else if (result && result.error) {
        aiError = result.error;
        render();
      }
    } catch (error) {
      aiError = '选择图片失败：' +
        (error && error.message ? error.message : error);
      render();
    }
  }

  /**
   * AI 返回的公式分隔符不稳定：同一个模型可能随机使用
   * $...$ / $$...$$ / \(...\) / \[...\]，还偶尔包 Markdown 围栏。
   * 统一转成 KaTeX auto-render 最稳定的 $...$ / $$...$$。
   */
  function normalizeAiMath(text) {
    var s = String(text || '');
    s = s.replace(/```(?:latex|tex|math)?\s*([\s\S]*?)```/gi, function (_, body) {
      return body.trim();
    });
    s = s.replace(/\\\(([\s\S]*?)\\\)/g, function (_, body) {
      return '$' + body.trim() + '$';
    });
    s = s.replace(/\\\[([\s\S]*?)\\\]/g, function (_, body) {
      return '$$' + body.trim() + '$$';
    });
    // fmt() 会把换行变成 <br>，而 auto-render 无法跨 <br> 匹配 $$
    // 块；先把 display math 内部压成一行，保证公式落在一个文本节点里。
    s = s.replace(/\$\$([\s\S]*?)\$\$/g, function (_, body) {
      return '$$' + body.replace(/\s+/g, ' ').trim() + '$$';
    });
    return s;
  }

  function buildAiPrompt(studentAnswer) {
    var q = ctx.question;
    var isFill = q.type === 'fill_blank';
    var options = (q.options || []).map(function (option) {
      return option.key + '. ' + option.text;
    }).join('\n');
    var selectedText = (q.options || []).filter(function (option) {
      return (ctx.selected || []).indexOf(option.key) >= 0;
    }).map(function (option) {
      return option.key + '. ' + option.text;
    }).join(' / ');

    var lines = [
      '你是大学课程答疑老师。请针对下面这道题给出解析。',
      '',
      '要求：'
    ];
    if (options) {
      lines.push(
        '- 说明正确答案为什么正确；',
        '- 简要说明其它选项为什么不对；'
      );
    } else {
      lines.push(
        '- 给出清晰的解题思路和完整推导步骤；',
        '- 如果附有学生作答，指出思路是否正确、错在哪里、应如何改正；'
      );
    }
    lines.push(
      '- 如果有附图，结合图片内容解释；',
      '- 数学表达式一律用 LaTeX 表示：行内公式用 $...$，独立公式用 $$...$$；',
      '- 每个公式都必须完整包在 $...$ 或 $$...$$ 里，禁止把 \\frac、\\sqrt 等命令裸写在正文中，',
      '  例如必须写 $\\frac{1}{2}$，不能写 \\frac{1}{2}；',
      '- 不要使用 \\(...\\) 或 \\[...\\] 作为公式分隔符；',
      '- 公式内不要夹杂中文，需要中文说明时写在公式外面；',
      '- 不要用 Unicode 符号或纯文本凑合（例如写 $x^2$ 而不是 x^2）；',
      '- 输出纯文本，不要 Markdown 标记、不要用星号或井号分点；',
      '- 控制在 300 字以内。',
      '',
      '题目：' + q.question
    );
    if (options) {
      lines.push('', '选项：', options);
    }
    lines.push('', '正确答案：' + (ctx.correctAnswerText || ''));
    if (isFill && studentAnswer) {
      lines.push('', '学生作答：' + studentAnswer);
    } else if (!isFill && selectedText) {
      lines.push('', '学生选择：' + selectedText);
    }
    return lines.join('\n');
  }

  async function requestAi() {
    if (aiLoading) return;
    aiLoading = true;
    render();
    try {
      var textarea = document.getElementById('answer');
      var answer = textarea ? textarea.value : answerText;
      var images = [];
      if (ctx.question.imageDataUrl) images.push(ctx.question.imageDataUrl);
      if (ctx.question.type === 'fill_blank') {
        images = images.concat(answerImages);
      }
      var result = await hostCall('tbankAiComplete', {
        prompt: buildAiPrompt(answer),
        images: images
      });
      aiText = typeof result === 'string'
        ? normalizeAiMath(result)
        : '（AI 没有返回内容）';
    } catch (error) {
      aiText = 'AI 解析失败：' + (error && error.message ? error.message : error);
    } finally {
      aiLoading = false;
      render();
    }
  }
})();
