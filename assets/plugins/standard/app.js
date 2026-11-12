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
  // AI 解析之后的追问对话：{role:'user'|'ai', text:string}
  var aiThread = [];
  var followUpText = '';
  var followUpLoading = false;
  var showAnswer = false;
  var lastQuestionId = '';
  var pendingCalls = {};
  var callSeq = 0;
  var scratchOpen = false;
  var scratchBoard = null;
  var scratchTool = 'pen';
  var scratchStrokes = [];
  var scratchEraserMode = 'pixel';
  var scratchPenWidth = 3;
  var scratchGrid = true;
  // 笔尖双击判定间隔，由 App 的「手写笔设置」通过 context.settings 注入。
  var scratchDoubleTapMs = 320;
  // 手写板是否屏蔽手指：true 时只有笔能落笔，手指只负责滚动。
  var scratchPenOnly = false;

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

  // 手写板参数沿用上次用的：换题、换题库都从 context.settings 恢复，
  // 用户调过的笔宽 / 橡皮模式 / 网格不会被重置。
  function applyPenSettingsFrom(settings) {
    if (!settings) return;
    var width = Number(settings.penWidth);
    if (isFinite(width) && width > 0) {
      scratchPenWidth = Math.max(1, Math.min(12, Math.round(width)));
    }
    if (settings.eraserMode === 'stroke' || settings.eraserMode === 'pixel') {
      scratchEraserMode = settings.eraserMode;
    }
    if (typeof settings.grid === 'boolean') {
      scratchGrid = settings.grid;
    }
  }

  // 把当前手写板参数回传给 App 保存，下次进别的题库继续用。
  function savePenSettings(patch) {
    hostCall('tbankSetPenSettings', patch).catch(function () {
      /* 保存失败不影响写字 */
    });
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
      aiThread = [];
      followUpText = '';
      followUpLoading = false;
      showAnswer = false;
      scratchOpen = false;
      scratchStrokes = [];
      if (scratchBoard) {
        scratchBoard.dispose();
        scratchBoard = null;
      }
      applyPenSettingsFrom(next.settings);
      lastQuestionId = id;
    } else if (Array.isArray(next.selected)) {
      selected = new Set(next.selected);
    }

    ctx = next;
    if (next.answered) showAnswer = true;
    // App 设置页的「笔尖双击间隔」随 context 下发；没给就沿用 320ms。
    if (next.settings && Number(next.settings.penDoubleTapMs) > 0) {
      scratchDoubleTapMs = Number(next.settings.penDoubleTapMs);
    }
    // 「手写板屏蔽手指」开关同样随 context 下发。
    if (next.settings && typeof next.settings.penOnlyInput === 'boolean') {
      scratchPenOnly = next.settings.penOnlyInput;
    }
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

    var html = '<div class="practice-main">';
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
        '<button class="outline" data-action="pick-camera">拍照</button>' +
        '<button class="outline" data-action="pick-gallery">从相册选择</button></div>';
      if (ctx.aiEnabled) {
        html += '<div class="row">' +
          '<button class="primary" data-action="ai-submit"' +
          (aiScoring ? ' disabled' : '') + '>' +
          (aiScoring ? 'AI 判分中…' : '提交（AI 判分）') + '</button></div>';
      }
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
        html += '<div class="card ai-card"><div class="card-title">AI 解析</div>' +
          '<div class="line" id="ai-answer">' + fmt(aiText) + '</div>';
        // 追问对话流：解析之后再问的问题按「你 / AI」逐轮追加
        if (aiThread.length) {
          html += '<div class="ai-thread">';
          aiThread.forEach(function (turn) {
            html += '<div class="ai-turn ' + (turn.role === 'user' ? 'is-user' : 'is-ai') + '">' +
              '<div class="ai-turn-role">' + (turn.role === 'user' ? '你' : 'AI') + '</div>' +
              '<div class="ai-turn-text">' + fmt(turn.text) + '</div></div>';
          });
          html += '</div>';
        }
        // 追问输入窗：解析下面的常驻入口，回车（不带 Shift）也能发送
        html += '<div class="ai-followup">' +
          '<textarea class="answer-box ai-followup-box" id="followup" rows="2"' +
          (followUpLoading ? ' disabled' : '') +
          ' placeholder="还有哪里不明白？在这里继续追问">' +
          esc(followUpText) + '</textarea>' +
          '<div class="row"><button class="primary" data-action="ai-followup"' +
          (followUpLoading ? ' disabled' : '') + '>' +
          (followUpLoading ? 'AI 回答中…' : '追问') + '</button></div>' +
          '</div>';
        html += '</div>';
      }
    } else if (isFill && showAnswer) {
      html += '<div class="card"><div class="card-title">参考答案</div>' +
        '<div class="line">' + fmt(ctx.correctAnswerText || '') + '</div></div>';
      if (q.analysis) {
        html += '<div class="card analysis"><div class="card-title">解析</div>' +
          '<div class="line">' + fmt(q.analysis) + '</div></div>';
      }
    }

    // 最下方的手写区入口：所有题型都可以当草稿用；
    // 填空/证明题可以把画布直接加入作答图片。
    var scratchTitle = isFill ? '手写作答' : '手写草稿';
    html += '<div class="scratch-toggle-row">' +
      '<button class="outline" data-action="scratch-toggle">' +
      (scratchOpen ? '收起手写区' : '展开手写区') + '</button></div>';
    html += '</div>'; // practice-main

    if (scratchOpen) {
      var eraserHidden = scratchTool === 'eraser' ? '' : ' hidden';
      html += '<div class="scratch-wrap" id="scratch-wrap">' +
        '<div class="scratch-head"><span>' + scratchTitle + '</span>' +
        '<span class="scratch-tip">' +
        (scratchPenOnly
          ? '仅手写笔 · 笔杆键或笔尖双击切换工具'
          : '压感笔 / 数位板 · 笔杆键或笔尖双击切换工具') +
        '</span></div>' +
        '<div class="scratch-board-wrap"><canvas class="scratch-board"></canvas></div>' +
        '<div class="scratch-tools">' +
        '<button class="outline scratch-tool" id="btn-pen" data-action="scratch-toggle-tool">笔</button>' +
        '<span class="scratch-group">' +
        '<input class="scratch-width" id="scratch-width" type="range" min="1" max="12" step="1" value="' +
        scratchPenWidth + '">' +
        '<span class="scratch-width-value" id="scratch-width-value">' +
        scratchPenWidth + 'px</span></span>' +
        '<button class="outline scratch-mode" id="btn-pixel" data-action="scratch-mode-pixel"' +
        eraserHidden + '>精确</button>' +
        '<button class="outline scratch-mode" id="btn-stroke" data-action="scratch-mode-stroke"' +
        eraserHidden + '>整笔</button>' +
        '<button class="outline" data-action="scratch-undo">撤销</button>' +
        '<button class="outline" data-action="scratch-clear">清空</button>' +
        '<button class="outline" id="btn-grid" data-action="scratch-grid">网格</button>' +
        (isFill && !answered && !showAnswer
          ? '<button class="primary" data-action="scratch-add">加入作答</button>'
          : '') +
        '</div></div>';
    }

    app.className = 'app' + (scratchOpen ? ' has-scratch' : '');
    app.innerHTML = html;
    bind();
    renderMath(0);
    mountScratch();
  }

  function mountScratch() {
    if (scratchBoard) {
      scratchStrokes = scratchBoard.exportStrokes();
      scratchBoard.dispose();
      scratchBoard = null;
    }
    if (!scratchOpen) return;
    var canvas = document.querySelector('.scratch-board');
    if (!canvas) return;
    if (typeof DrawBoard === 'undefined') {
      scratchOpen = false;
      aiError = '手写组件未加载';
      render();
      return;
    }
    scratchBoard = new DrawBoard(canvas, {
      penWidth: scratchPenWidth,
      grid: scratchGrid,
      eraserMode: scratchEraserMode,
      doubleTapMs: scratchDoubleTapMs,
      penOnly: scratchPenOnly,
      tool: scratchTool === 'eraser' ? 'eraser' : 'pen',
      onGesture: function () {
        toggleScratchTool(true);
      }
    });
    scratchBoard.mount();
    if (scratchStrokes.length > 0) {
      scratchBoard.importStrokes(scratchStrokes);
    }
    updateScratchToolUI();
  }

  // 切换笔/橡皮的悬浮提示：手写区上方淡入淡出，不走宿主的 SnackBar。
  var penHintEl = null;
  var penHintTimer = null;

  function showPenHint(text) {
    if (!document.body) return;
    if (!penHintEl) {
      penHintEl = document.createElement('div');
      penHintEl.className = 'pen-hint';
      document.body.appendChild(penHintEl);
    }
    penHintEl.textContent = text;
    penHintEl.classList.remove('is-on');
    // 读一次布局，让动画能从起点重新播放
    void penHintEl.offsetWidth;
    penHintEl.classList.add('is-on');

    if (penHintTimer) clearTimeout(penHintTimer);
    penHintTimer = setTimeout(function () {
      penHintEl.classList.remove('is-on');
    }, 900);
  }

  // 切换笔/橡皮：不动 DOM，只改状态和按钮外观，避免重绘把笔迹清掉。
  function applyScratchTool(tool, notify) {
    var next = tool === 'eraser' ? 'eraser' : 'pen';
    scratchTool = next;
    if (scratchBoard) scratchBoard.setTool(next);
    updateScratchToolUI();
    if (notify) showPenHint(next === 'eraser' ? '橡皮' : '笔');
  }

  function toggleScratchTool(notify) {
    applyScratchTool(scratchTool === 'eraser' ? 'pen' : 'eraser', notify);
  }

  function setScratchEraserMode(mode) {
    scratchEraserMode = mode === 'stroke' ? 'stroke' : 'pixel';
    if (scratchBoard) scratchBoard.setEraserMode(scratchEraserMode);
    updateScratchToolUI();
    savePenSettings({ eraserMode: scratchEraserMode });
  }

  function updateScratchToolUI() {
    var isEraser = scratchTool === 'eraser';
    var penButton = document.getElementById('btn-pen');
    if (penButton) {
      penButton.textContent = isEraser ? '橡皮' : '笔';
      penButton.classList.toggle('is-eraser', isEraser);
    }
    var pixel = document.getElementById('btn-pixel');
    if (pixel) {
      pixel.hidden = !isEraser;
      pixel.classList.toggle('active', scratchEraserMode === 'pixel');
    }
    var stroke = document.getElementById('btn-stroke');
    if (stroke) {
      stroke.hidden = !isEraser;
      stroke.classList.toggle('active', scratchEraserMode === 'stroke');
    }
    var grid = document.getElementById('btn-grid');
    if (grid) grid.classList.toggle('active', scratchGrid);
    var width = document.getElementById('scratch-width');
    if (width) width.value = String(scratchPenWidth);
    var widthValue = document.getElementById('scratch-width-value');
    if (widthValue) widthValue.textContent = scratchPenWidth + 'px';
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
        } else if (action === 'ai-followup') {
          requestFollowUp();
        } else if (action === 'ai-submit') {
          submitFillAi();
        } else if (action === 'pick-camera') {
          pickImage('camera');
        } else if (action === 'pick-gallery') {
          pickImage('gallery');
        } else if (action === 'scratch-toggle') {
          scratchOpen = !scratchOpen;
          if (!scratchOpen && scratchBoard) {
            scratchStrokes = scratchBoard.exportStrokes();
            scratchBoard.dispose();
            scratchBoard = null;
          }
          render();
        } else if (action === 'scratch-toggle-tool') {
          toggleScratchTool(true);
        } else if (action === 'scratch-pen') {
          applyScratchTool('pen');
        } else if (action === 'scratch-eraser') {
          applyScratchTool('eraser');
        } else if (action === 'scratch-mode-pixel') {
          setScratchEraserMode('pixel');
        } else if (action === 'scratch-mode-stroke') {
          setScratchEraserMode('stroke');
        } else if (action === 'scratch-grid') {
          scratchGrid = !scratchGrid;
          if (scratchBoard) scratchBoard.setGrid(scratchGrid);
          updateScratchToolUI();
          savePenSettings({ grid: scratchGrid });
        } else if (action === 'scratch-undo') {
          if (scratchBoard) scratchBoard.undo();
        } else if (action === 'scratch-clear') {
          if (scratchBoard) scratchBoard.clear();
          scratchStrokes = [];
        } else if (action === 'scratch-add') {
          addScratchToAnswer();
        }
      });
    });

    var textarea = document.getElementById('answer');
    if (textarea) {
      textarea.addEventListener('input', function () {
        answerText = textarea.value;
      });
    }

    // 追问输入：只存状态不重绘（重绘会丢焦点），点按钮 / 回车时才发送。
    var followup = document.getElementById('followup');
    if (followup) {
      followup.addEventListener('input', function () {
        followUpText = followup.value;
      });
      followup.addEventListener('keydown', function (event) {
        var key = event.key || '';
        if (key !== 'Enter' || event.shiftKey) return; // Shift+Enter 换行
        if (event.preventDefault) event.preventDefault();
        requestFollowUp();
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

    var widthRange = document.getElementById('scratch-width');
    if (widthRange) {
      widthRange.addEventListener('input', function () {
        var value = Number(widthRange.value) || 3;
        scratchPenWidth = Math.max(1, Math.min(12, value));
        if (scratchBoard) scratchBoard.setPenWidth(scratchPenWidth);
        var label = document.getElementById('scratch-width-value');
        if (label) label.textContent = scratchPenWidth + 'px';
      });
      // 松手才落盘，拖动过程中不用每帧写文件
      widthRange.addEventListener('change', function () {
        savePenSettings({ width: scratchPenWidth });
      });
    }
  }

  // 蓝牙笔 / 系统手势通道：App 收到 194~197 后转发过来，195 是双击。
  // 手写区没展开时什么也不做，避免误切。
  window.__tbankPenGesture = function (code) {
    if (Number(code) !== 195) return false;
    if (!scratchOpen || !scratchBoard) return false;
    toggleScratchTool(true);
    return true;
  };

  // WebView 自己收到按键时（部分设备会把 195 透传到页面）也接一下。
  document.addEventListener('keydown', function (event) {
    var code = event.keyCode || event.which;
    if (code !== 195) return;
    if (event.preventDefault) event.preventDefault();
    window.__tbankPenGesture(195);
  });

  function submitChoice() {
    var correctSet = new Set(ctx.question.correctAnswers || []);
    var ok = selected.size === correctSet.size &&
      Array.from(selected).every(function (key) { return correctSet.has(key); });
    hostCall('tbankSubmit', { correct: ok, selected: Array.from(selected) });
  }

  function addScratchToAnswer() {
    if (!ctx || ctx.question.type !== 'fill_blank') return;
    if (answerImages.length >= 4) {
      hostCall('tbankToast', { message: '最多上传 4 张作答图片' });
      return;
    }
    if (!scratchBoard || scratchBoard.isEmpty()) {
      hostCall('tbankToast', { message: '手写区还没有内容' });
      return;
    }
    answerImages.push(scratchBoard.toPngDataUrl({ maxEdge: 1600, crop: true }));
    scratchOpen = false;
    scratchStrokes = [];
    aiError = '';
    render();
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

  async function pickImage(source) {
    if (answerImages.length >= 4) {
      aiError = '最多上传 4 张作答图片';
      render();
      return;
    }
    try {
      var result = await hostCall('tbankPickImage', { source: source });
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
    aiThread = []; // 重新解析：上一轮追问作废
    followUpText = '';
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

  /**
   * 追问的 Prompt：把题干、答案、上一轮解析和已有的问答一起带上，
   * 让模型能接着上下文回答，而不是把整段解析再讲一遍。
   */
  function buildFollowUpPrompt(question) {
    var q = ctx.question;
    var options = (q.options || []).map(function (option) {
      return option.key + '. ' + option.text;
    }).join('\n');

    var lines = [
      '你是大学课程答疑老师，正在给一名学生讲解下面这道题。',
      '',
      '题目：' + q.question
    ];
    if (options) lines.push('', '选项：', options);
    lines.push('', '正确答案：' + (ctx.correctAnswerText || ''));
    lines.push('', '你之前给出的解析：', aiText);
    if (aiThread.length) {
      lines.push('', '之后的对话：');
      aiThread.forEach(function (turn) {
        lines.push((turn.role === 'user' ? '学生：' : '你：') + turn.text);
      });
    }
    lines.push(
      '',
      '学生现在追问：' + question,
      '',
      '要求：',
      '- 直接回答这个追问，不要重抄整段解析，也不要重复已经说过的内容；',
      '- 数学表达式一律用 LaTeX：行内用 $...$，独立公式用 $$...$$，禁止把 \\frac、\\sqrt 等命令裸写在正文里；',
      '- 公式内不要夹杂中文，需要中文说明时写在公式外面；',
      '- 不要用 Unicode 符号或纯文本凑合；',
      '- 输出纯文本，不要 Markdown 标记；',
      '- 控制在 250 字以内。'
    );
    return lines.join('\n');
  }

  /** 发送一次追问；成功后把问答追加进 [aiThread]。 */
  async function requestFollowUp() {
    if (!ctx || !ctx.question || followUpLoading) return;

    var textarea = document.getElementById('followup');
    if (textarea) followUpText = textarea.value;
    var question = String(followUpText || '').trim();
    if (!question) {
      hostCall('tbankToast', { message: '先写点想问的内容' }).catch(function () {});
      return;
    }

    followUpLoading = true;
    render();
    try {
      var images = [];
      if (ctx.question.imageDataUrl) images.push(ctx.question.imageDataUrl);
      var result = await hostCall('tbankAiComplete', {
        prompt: buildFollowUpPrompt(question),
        images: images
      });
      var answer = typeof result === 'string'
        ? normalizeAiMath(result)
        : '（AI 没有返回内容）';
      aiThread.push({ role: 'user', text: question });
      aiThread.push({ role: 'ai', text: answer });
    } catch (error) {
      aiThread.push({ role: 'user', text: question });
      aiThread.push({
        role: 'ai',
        text: '追问失败：' + (error && error.message ? error.message : error)
      });
    } finally {
      followUpText = ''; // 问题已经进对话流，输入框清空
      followUpLoading = false;
      render();
    }
  }
})();
