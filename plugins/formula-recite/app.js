// TBank 公式默写插件：练习页装配、判分状态机、计时。
// 顶部只做定义，初始化放在文件末尾：Node 测试环境没有 document，不能碰 DOM。
(function () {
  "use strict";

  var BADGE = "公式默写";
  var PHASES = { idle: "idle", grading: "grading", confirm: "confirm", selfCheck: "selfCheck", submitted: "submitted" };

  var state = {
    context: null,
    model: null,
    root: null,
    board: null,
    canvas: null,
    tool: "pen",
    eraserMode: "pixel",
    penWidth: 3,
    applyTool: null,
    gestureBound: false,
    canvasGestureBound: false,
    lastPenTap: null,
    phase: PHASES.idle,
    submitted: false,
    verdict: null,
    aiError: "",
    explainText: "",
    explainCache: {},
    config: null,
    timer: null,
    elapsed: 0,
    epoch: 0,
    aiRaw: "",
    draftStrokes: [],
    draftScrollLeft: 0,
    draftScrollTop: 0,
    draftQuestionId: ""
  };

  function normalizeContext(ctx) {
    var source = ctx && typeof ctx === "object" ? ctx : {};
    var question = source.question && typeof source.question === "object" ? source.question : {};
    var pluginData = question.pluginData && typeof question.pluginData === "object" ? question.pluginData : {};
    var raw = Array.isArray(question.correctAnswers)
      ? question.correctAnswers
      : Array.isArray(question.correctAnswer)
      ? question.correctAnswer
      : [];
    var answers = [];
    for (var i = 0; i < raw.length; i++) {
      if (typeof raw[i] === "string" && raw[i].trim() !== "") answers.push(raw[i]);
    }
    var latex = typeof pluginData.latex === "string" && pluginData.latex.trim() !== ""
      ? pluginData.latex
      : answers[0] || "";
    var stats = question.stats && typeof question.stats === "object" ? question.stats : {};
    return {
      question: String(question.question || ""),
      correctAnswer: answers,
      latex: latex,
      hint: typeof pluginData.hint === "string" ? pluginData.hint : "",
      stats: {
        attemptCount: Number(stats.attemptCount) || 0,
        wrongCount: Number(stats.wrongCount) || 0
      },
      answered: source.answered === true
    };
  }

  function h(tag, className, text) {
    var node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined && text !== null) node.textContent = String(text);
    return node;
  }

  function clear(node) {
    while (node.firstChild) node.removeChild(node.firstChild);
  }

  function texBlock(source) {
    var box = h("div", "tex");
    box.innerHTML = typeof renderTex === "function" ? renderTex(source || "") : String(source || "");
    return box;
  }

  // 中文句子 + $公式$ 混排：题干、提示、解析、AI 返回都走这里。
  function richHtml(text) {
    if (typeof renderRich === "function") return renderRich(text);
    return typeof renderTex === "function" ? renderTex(text) : String(text || "");
  }

  function hRich(tag, className, source) {
    var node = h(tag, className);
    node.innerHTML = richHtml(source);
    return node;
  }

  function escapeAiHtml(value) {
    return String(value === undefined || value === null ? "" : value)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#39;");
  }

  // AI 返回的公式分隔符不稳定：可能混用 $...$ / $$...$$ / \(...\) / \[...\]，
  // 还可能把公式包在 ```latex 围栏里。统一成 renderRich 认识的 $ / $$。
  function normalizeAiMath(text) {
    var value = String(text === undefined || text === null ? "" : text);
    value = value.replace(/```(?:latex|tex|math)\s*([\s\S]*?)```/gi, function (_, body) {
      return "\n$$" + body.replace(/\s+/g, " ").trim() + "$$\n";
    });
    value = value.replace(/\\\[([\s\S]*?)\\\]/g, function (_, body) {
      return "\n$$" + body.replace(/\s+/g, " ").trim() + "$$\n";
    });
    value = value.replace(/\\\(([\s\S]*?)\\\)/g, function (_, body) {
      return "$" + body.trim() + "$";
    });
    // 多行 display math 先压成一行，避免段落换行把它拆开
    value = value.replace(/\$\$([\s\S]*?)\$\$/g, function (_, body) {
      return "$$" + body.replace(/\s+/g, " ").trim() + "$$";
    });
    return value;
  }

  function inlineAiMarkdown(text) {
    var html = typeof renderRich === "function" ? renderRich(text) : escapeAiHtml(text);
    html = html.replace(/`([^`\n]+)`/g, function (_, code) {
      return "<code>" + code + "</code>";
    });
    html = html.replace(/\*\*([^*\n]+)\*\*/g, "<strong>$1</strong>");
    html = html.replace(/(^|[^*])\*([^*\n]+)\*(?!\*)/g, "$1<em>$2</em>");
    return html;
  }

  function startsMarkdownBlock(line) {
    return /^\s*(#{1,6})\s+/.test(line) ||
      /^\s*([-*+])\s+/.test(line) ||
      /^\s*\d+[.)]\s+/.test(line) ||
      /^\s*>\s?/.test(line) ||
      /^\s*```/.test(line) ||
      /^\s*([-*_]\s*){3,}$/.test(line);
  }

  // AI 解析专用：支持标题、加粗/斜体、行内代码、围栏代码、列表、引用和 $...$ 公式。
  function renderAiMarkdown(text) {
    var lines = normalizeAiMath(text).replace(/\r\n?/g, "\n").split("\n");
    var out = [];
    var i = 0;
    while (i < lines.length) {
      var line = lines[i];
      if (!line.trim()) {
        i++;
        continue;
      }

      if (/^\s*```/.test(line)) {
        var code = [];
        i++;
        while (i < lines.length && !/^\s*```/.test(lines[i])) {
          code.push(lines[i]);
          i++;
        }
        if (i < lines.length) i++;
        out.push("<pre><code>" + escapeAiHtml(code.join("\n")) + "</code></pre>");
        continue;
      }

      var heading = line.match(/^\s*(#{1,6})\s+(.*)$/);
      if (heading) {
        var level = Math.min(6, heading[1].length);
        out.push("<h" + level + ">" + inlineAiMarkdown(heading[2]) + "</h" + level + ">");
        i++;
        continue;
      }

      if (/^\s*([-*_]\s*){3,}$/.test(line)) {
        out.push("<hr>");
        i++;
        continue;
      }

      var ordered = /^\s*\d+[.)]\s+/.test(line);
      if (ordered || /^\s*[-*+]\s+/.test(line)) {
        var items = [];
        while (i < lines.length) {
          var item = ordered
            ? lines[i].match(/^\s*\d+[.)]\s+(.*)$/)
            : lines[i].match(/^\s*[-*+]\s+(.*)$/);
          if (!item) break;
          items.push("<li>" + inlineAiMarkdown(item[1]) + "</li>");
          i++;
        }
        out.push((ordered ? "<ol>" : "<ul>") + items.join("") + (ordered ? "</ol>" : "</ul>"));
        continue;
      }

      if (/^\s*>\s?/.test(line)) {
        var quote = [];
        while (i < lines.length && /^\s*>\s?/.test(lines[i])) {
          quote.push(lines[i].replace(/^\s*>\s?/, ""));
          i++;
        }
        out.push("<blockquote>" + inlineAiMarkdown(quote.join(" ")) + "</blockquote>");
        continue;
      }

      var paragraph = [line.trim()];
      i++;
      while (i < lines.length && lines[i].trim() && !startsMarkdownBlock(lines[i])) {
        paragraph.push(lines[i].trim());
        i++;
      }
      out.push("<p>" + inlineAiMarkdown(paragraph.join(" ")) + "</p>");
    }
    return out.join("\n");
  }

  function setPhase(phase) {
    state.phase = phase;
    if (state.submitBtn) {
      state.submitBtn.disabled = phase !== PHASES.idle && phase !== PHASES.submitted;
    }
  }

  function buildTopbar() {
    var bar = h("div", "topbar");
    var ctx = state.context || {};
    var total = Number(ctx.total) || 1;
    var index = Number(ctx.index) || 0;
    bar.appendChild(h("span", "chip chip-index", "第 " + (index + 1) + " / " + total + " 题"));
    bar.appendChild(h("span", "chip chip-badge", BADGE));
    var model = state.model;
    var timerLabel = h("span", "timer");
    timerLabel.hidden = true;
    state.timerLabel = timerLabel;
    bar.appendChild(timerLabel);
    bar.appendChild(
      h("span", "chip chip-stats", "作答 " + model.stats.attemptCount + " · 错 " + model.stats.wrongCount)
    );
    state.topbar = bar;
    return bar;
  }

  function buildHint(hint) {
    var wrap = h("div", "hint-row");
    var button = h("button", "hint-toggle", "提示");
    var text = hRich("div", "hint-text", hint);
    text.hidden = true;
    button.addEventListener("click", function () {
      text.hidden = !text.hidden;
      button.textContent = text.hidden ? "提示" : "收起提示";
    });
    wrap.appendChild(button);
    wrap.appendChild(text);
    return wrap;
  }

  function buildBoard() {
    var wrap = h("div", "board-wrap");
    var canvas = h("canvas", "board");
    wrap.appendChild(canvas);
    state.canvas = canvas;
    state.canvasGestureBound = false;
    return wrap;
  }

  function buildToolbar() {
    var bar = h("div", "toolbar");
    var configured = state.config && Number(state.config.penWidth) ? Number(state.config.penWidth) : 3;
    state.penWidth = configured;

    // 工具组：笔/橡皮按钮 + 粗细滑块（原来三个粗细按钮合并到这里）
    var style = h("div", "tool-group tool-pen");
    var penButton = h("button", "tool tool-mode active", "\u270f\ufe0f \u7b14");
    var widthRange = h("input", "width-range");
    widthRange.type = "range";
    widthRange.min = "1";
    widthRange.max = "12";
    widthRange.step = "1";
    widthRange.value = String(configured);
    var widthValue = h("span", "width-value", configured + "px");

    var eraserModes = h("div", "tool-group eraser-modes");
    eraserModes.hidden = state.tool !== "eraser";

    function applyTool(tool) {
      var name = tool === "eraser" ? "eraser" : "pen";
      state.tool = name;
      if (state.board) {
        state.board.setTool(name);
        if (name === "eraser") state.board.setEraserMode(state.eraserMode);
      }
      penButton.textContent = name === "eraser" ? "\ud83e\uddfd \u6a61\u76ae" : "\u270f\ufe0f \u7b14";
      penButton.classList.toggle("is-eraser", name === "eraser");
      eraserModes.hidden = name !== "eraser";
    }
    state.applyTool = applyTool;

    penButton.addEventListener("click", function () {
      applyTool(state.tool === "eraser" ? "pen" : "eraser");
    });

    widthRange.addEventListener("input", function () {
      var value = Number(widthRange.value) || 3;
      state.penWidth = value;
      if (state.board) state.board.setPenWidth(value);
      widthValue.textContent = value + "px";
    });

    style.appendChild(penButton);
    style.appendChild(widthRange);
    style.appendChild(widthValue);

    var pixelBtn = h("button", "tool eraser-mode active", "\u7cbe\u786e");
    var strokeBtn = h("button", "tool eraser-mode", "\u6574\u7b14");
    function applyEraserMode(mode) {
      var name = mode === "stroke" ? "stroke" : "pixel";
      state.eraserMode = name;
      if (state.board) state.board.setEraserMode(name);
      pixelBtn.classList.toggle("active", name === "pixel");
      strokeBtn.classList.toggle("active", name === "stroke");
    }
    pixelBtn.addEventListener("click", function () {
      applyEraserMode("pixel");
    });
    strokeBtn.addEventListener("click", function () {
      applyEraserMode("stroke");
    });
    eraserModes.appendChild(pixelBtn);
    eraserModes.appendChild(strokeBtn);

    var edits = h("div", "tool-group");
    var undo = h("button", "tool", "\u64a4\u9500");
    var wipe = h("button", "tool", "\u6e05\u7a7a");
    undo.addEventListener("click", function () {
      if (state.board) state.board.undo();
    });
    wipe.addEventListener("click", function () {
      if (state.board) state.board.clear();
    });
    edits.appendChild(undo);
    edits.appendChild(wipe);

    var toggles = h("div", "tool-group");
    var gridButton = h("button", "tool active", "\u7f51\u683c");
    gridButton.addEventListener("click", function () {
      if (!state.board) return;
      var on = !state.board.grid;
      state.board.setGrid(on);
      gridButton.classList.toggle("active", on);
    });
    var gridOn = !state.config || state.config.showGrid !== false;
    gridButton.classList.toggle("active", gridOn);
    toggles.appendChild(gridButton);

    bar.appendChild(style);
    bar.appendChild(eraserModes);
    bar.appendChild(edits);
    bar.appendChild(toggles);
    return bar;
  }

  function buildActions() {
    var wrap = h("div", "actions");
    var submit = h("button", "primary", "\u63d0\u4ea4\u9ed8\u5199");
    submit.addEventListener("click", onPrimaryAction);
    state.submitBtn = submit;
    wrap.appendChild(submit);
    return wrap;
  }

  // 主按钮：未作答时提交；已提交后原地变成「下一题」
  function onPrimaryAction() {
    if (state.phase === PHASES.submitted) {
      call("tbankNext", {});
      return;
    }
    onSubmit();
  }

  function updatePrimaryButton(mode) {
    var button = state.submitBtn;
    if (!button) return;
    if (mode === "next") {
      button.textContent = "\u4e0b\u4e00\u9898";
      button.disabled = false;
      return;
    }
    button.textContent = "\u63d0\u4ea4\u9ed8\u5199";
    button.disabled = state.phase !== PHASES.idle;
  }

  function buildResultHost() {
    var host = h("div", "result-host");
    state.resultHost = host;
    return host;
  }

  function mountBoard() {
    if (state.board) {
      state.draftStrokes = state.board.exportStrokes();
      var oldScroller = state.board.canvas.parentElement;
      if (oldScroller) {
        state.draftScrollLeft = oldScroller.scrollLeft;
        state.draftScrollTop = oldScroller.scrollTop;
      }
      state.board.dispose();
    }
    var canvas = state.root ? state.root.querySelector("canvas.board") : null;
    if (!canvas) return;
    if (state.model && state.model.answered) {
      canvas.classList.add("is-locked");
      return;
    }
    var config = state.config || DEFAULT_CONFIG_FALLBACK;
    state.board = new DrawBoard(canvas, {
      penWidth: state.penWidth || config.penWidth,
      grid: config.showGrid,
      tool: state.tool === "eraser" ? "eraser" : "pen",
      eraserMode: state.eraserMode
    });
    state.board.mount();
    if (state.draftStrokes.length > 0) {
      state.board.importStrokes(state.draftStrokes);
    }
    var scroller = canvas.parentElement;
    if (scroller) {
      scroller.scrollLeft = state.draftScrollLeft;
      scroller.scrollTop = state.draftScrollTop;
    }
    bindCanvasPenGesture();
  }

  function renderPage(root, model) {
    if (!root) return;
    state.root = root;
    state.model = model;
    clear(root);
    if (root.classList) root.classList.remove("has-result");

    var leftPane = h("div", "left-pane");
    leftPane.appendChild(buildTopbar());
    var questionPane = h("div", "question-pane");
    questionPane.appendChild(hRich("h1", "title", model.question || "（无题干）"));
    if (model.hint) questionPane.appendChild(buildHint(model.hint));
    leftPane.appendChild(questionPane);
    leftPane.appendChild(buildToolbar());
    leftPane.appendChild(buildActions());
    leftPane.appendChild(buildResultHost());
    root.appendChild(leftPane);
    root.appendChild(buildBoard());
    mountBoard();
    startTimer();
  }

  var DEFAULT_CONFIG_FALLBACK = {
    timerMode: "off",
    timeLimit: 60,
    timeoutAction: "autoSubmit",
    penWidth: 3,
    showGrid: true,
    autoCrop: true,
    aiExplainAuto: false
  };

  function createTimer(config, handlers) {
    config = config || {};
    handlers = handlers || {};
    var mode = config.mode === "stopwatch" ? "stopwatch" : config.mode === "countdown" ? "countdown" : "off";
    var limit = Number(config.limit);
    if (!isFinite(limit) || limit <= 0) limit = 60;
    var now = typeof handlers.now === "function" ? handlers.now : function () { return Date.now(); };
    var auto = handlers.auto !== false;
    var running = false;
    var startedAt = 0;
    var fired = false;
    var interval = null;

    function secondsSince() {
      return Math.max(0, Math.floor((now() - startedAt) / 1000));
    }

    function remaining() {
      if (mode !== "countdown") return null;
      return Math.max(0, limit - secondsSince());
    }

    function elapsed() {
      return secondsSince();
    }

    function poll() {
      if (!running) return;
      if (mode === "countdown") {
        var left = remaining();
        if (handlers.tick) handlers.tick(left);
        if (left <= 0 && !fired) {
          fired = true;
          stop();
          if (handlers.timeout) handlers.timeout();
        }
        return;
      }
      if (mode === "stopwatch" && handlers.tick) handlers.tick(elapsed());
    }

    function start() {
      running = true;
      fired = false;
      startedAt = now();
      if (auto && typeof setInterval === "function") {
        if (interval) clearInterval(interval);
        interval = setInterval(poll, 250);
      }
      poll();
    }

    function stop() {
      running = false;
      if (interval) {
        clearInterval(interval);
        interval = null;
      }
    }

    return { start: start, stop: stop, poll: poll, remaining: remaining, elapsed: elapsed };
  }

  function onTimeoutAction(action, handlers) {
    handlers = handlers || {};
    if (action === "autoSubmit") {
      var empty = typeof handlers.isEmpty === "function" ? handlers.isEmpty() : false;
      if (empty) {
        if (handlers.markWrong) handlers.markWrong();
        return;
      }
      if (handlers.submit) handlers.submit();
      return;
    }
    if (action === "markWrong") {
      if (handlers.markWrong) handlers.markWrong();
      return;
    }
    if (handlers.toast) handlers.toast("时间到");
  }

  function renderTimer(seconds, config) {
    var label = state.timerLabel;
    if (!label) return;
    if (config.timerMode === "countdown") {
      label.textContent = "⏳ " + seconds + "s";
      label.classList.toggle("warn", seconds <= 10);
      state.elapsed = Math.max(0, (Number(config.timeLimit) || 60) - seconds);
    } else {
      label.textContent = "⏱ " + seconds + "s";
      state.elapsed = seconds;
    }
  }

  function handleTimeout(config) {
    var action = config.timeoutAction || "autoSubmit";
    if (action === "notify") {
      onTimeoutAction("notify", { toast: function (message) { call("tbankToast", { message: message }); } });
      return;
    }
    onTimeoutAction(action, {
      isEmpty: function () {
        return !state.board || state.board.isEmpty();
      },
      submit: function () {
        if (state.phase === PHASES.idle) onSubmit();
      },
      markWrong: function () {
        if (state.phase !== PHASES.idle) return;
        state.verdict = null;
        state.aiError = "时间到，没有完成默写";
        transition("SUBMIT");
        transition("AI_FAIL");
        renderResult("selfCheck");
      }
    });
  }

  function startTimer() {
    if (state.timer) {
      state.timer.stop();
      state.timer = null;
    }
    var config = state.config || DEFAULT_CONFIG_FALLBACK;
    if (!state.timerLabel) return;
    if (state.model && state.model.answered) {
      state.timerLabel.hidden = true;
      return;
    }
    if (!config.timerMode || config.timerMode === "off") {
      state.timerLabel.hidden = true;
      return;
    }
    state.timerLabel.hidden = false;
    state.timer = createTimer(
      { mode: config.timerMode, limit: config.timeLimit },
      {
        now: function () {
          return Date.now();
        },
        tick: function (seconds) {
          renderTimer(seconds, config);
        },
        timeout: function () {
          handleTimeout(config);
        }
      }
    );
    state.timer.start();
  }

  function recordUsage(seconds) {
    var value = Number(seconds) || 0;
    if (value <= 0) return;
    try {
      if (typeof localStorage === "undefined") return;
      var key = "formula-recite.usage";
      var today = new Date().toISOString().slice(0, 10);
      var raw = localStorage.getItem(key);
      var data = raw ? JSON.parse(raw) : null;
      if (!data || data.date !== today) data = { date: today, seconds: 0 };
      data.seconds += Math.round(value);
      localStorage.setItem(key, JSON.stringify(data));
    } catch (error) {
      /* 存储不可用时静默跳过 */
    }
  }

  function currentQuestionId() {
    var question = state.context && state.context.question;
    return question && question.id ? String(question.id) : "q";
  }

  function renderAnswerInto(parent) {
    var model = state.model;
    if (!model || (!model.correctAnswer.length && !model.latex)) {
      parent.appendChild(h("span", "note", "本题没有标准答案，只能自评"));
      return;
    }
    parent.appendChild(texBlock(model.latex || model.correctAnswer[0]));
    if (model.correctAnswer.length > 1) {
      parent.appendChild(hRich("div", "answer-alt", "也接受：" + model.correctAnswer.slice(1).join(" / ")));
    }
  }

  function renderResult(mode, forcedCorrect) {
    var host = state.resultHost;
    if (!host) return;
    if (state.root && state.root.classList) state.root.classList.add("has-result");
    updatePrimaryButton(mode === "submitted" ? "next" : "submit");
    clear(host);
    state.explainNode = null;
    state.explainBtn = null;
    var verdict = state.verdict;
    var recommended = mode === "confirm" ? recommendCorrect(verdict) : forcedCorrect === true;
    var card = h("div", "result");

    if (mode === "grading") {
      card.classList.add("is-grading");
      card.appendChild(h("div", "result-head", "AI 阅卷中…"));
      card.appendChild(h("div", "note", "正在把手写内容发给 DeepSeek 比对。最长等 120 秒，别急喵。"));
      host.appendChild(card);
      return;
    }

    // 判分区独立成一块：只有这块跟随对错变色。
    var panel = h("div", "result-verdict");
    if (mode === "confirm" || mode === "submitted") {
      panel.classList.add(recommended ? "is-correct" : "is-wrong");
    }

    var head = h("div", "result-head");
    if (mode === "confirm") {
      head.appendChild(h("span", "result-title", recommended ? "AI 判为正确" : "AI 判为错误"));
    } else if (mode === "submitted") {
      head.appendChild(h("span", "result-title", forcedCorrect ? "已记为作答对" : "已记为作答错"));
    } else {
      head.appendChild(h("span", "result-title", "AI 不可用，请自行判定"));
    }
    if (verdict && mode !== "selfCheck") {
      head.appendChild(h("span", "result-score", verdict.score + " / 10"));
    }
    panel.appendChild(head);

    if (verdict && (mode === "confirm" || mode === "submitted")) {
      var recognized = h("div", "result-row");
      recognized.appendChild(h("span", "result-label", "AI 读到的手写内容"));
      recognized.appendChild(document.createTextNode(verdict.recognized || "（没有识别出内容）"));
      panel.appendChild(recognized);
      if (verdict.reason) panel.appendChild(h("div", "note", verdict.reason));
    }

    var answerRow = h("div", "result-row");
    answerRow.appendChild(h("span", "result-label", "标准答案"));
    renderAnswerInto(answerRow);
    panel.appendChild(answerRow);

    if (state.aiError) panel.appendChild(h("div", "error-box", state.aiError));

    if (state.aiRaw) {
      var rawBox = h("details", "raw-ai");
      rawBox.appendChild(h("summary", "", "模型原文（排查用）"));
      rawBox.appendChild(h("pre", "raw-text", state.aiRaw));
      panel.appendChild(rawBox);
    }

    if (mode !== "submitted") {
      var buttons = h("div", "verdict-buttons");
      var yes = h("button", "verdict", "✓ 记作答对");
      var no = h("button", "verdict", "✗ 记作答错");
      if (recommended) yes.classList.add("suggest-correct");
      else no.classList.add("suggest-wrong");
      yes.addEventListener("click", function () {
        confirmVerdict(true);
      });
      no.addEventListener("click", function () {
        confirmVerdict(false);
      });
      buttons.appendChild(yes);
      buttons.appendChild(no);
      panel.appendChild(buttons);
    }
    card.appendChild(panel);

    // 解析区独立成块，始终保持白底，不受判分区红/绿背景影响。
    var detail = h("div", "result-detail");
    var actions = h("div", "result-actions");
    var aiEnabled = !!(state.context && state.context.aiEnabled);
    if (aiEnabled) {
      var explainBtn = h("button", "ghost", "AI 解析");
      explainBtn.addEventListener("click", function () {
        requestExplain(explainBtn);
      });
      state.explainBtn = explainBtn;
      actions.appendChild(explainBtn);
    }
    if (mode === "selfCheck" && aiEnabled) {
      var retry = h("button", "ghost", "重试 AI");
      retry.addEventListener("click", function () {
        if (!state.context || !state.context.aiEnabled) return;
        state.verdict = null;
        state.phase = PHASES.idle;
        startGrading();
      });
      actions.appendChild(retry);
    }
    if (actions.children.length > 0) detail.appendChild(actions);

    var analysis = state.context && state.context.question && state.context.question.analysis;
    if (typeof analysis === "string" && analysis.trim() !== "") {
      var analysisNode = h("div", "explain ai-rich");
      analysisNode.innerHTML = renderAiMarkdown(analysis);
      detail.appendChild(analysisNode);
    }

    if (aiEnabled) {
      var explainNode = h("div", "explain ai-rich");
      explainNode.hidden = true;
      state.explainNode = explainNode;
      detail.appendChild(explainNode);
    }

    if (detail.children.length > 0) card.appendChild(detail);

    host.appendChild(card);
  }

  function confirmVerdict(correct) {
    if (state.phase === PHASES.submitted) return;
    var label = state.verdict && state.phase === PHASES.confirm
      ? "AI:" + state.verdict.score + "分 记作答" + (correct ? "对" : "错")
      : "自评 记作答" + (correct ? "对" : "错");
    submitOnce(state, correct, function (flag) {
      return call("tbankSubmit", { correct: flag, selected: label });
    }).then(
      function (done) {
        if (!done) return;
        state.lastCorrect = correct;
        transition("CONFIRM");
        if (state.timer) state.timer.stop();
        recordUsage(state.elapsed || 0);
        if (state.board) {
          state.board.dispose();
          state.board = null;
        }
        renderResult("submitted", correct);
      },
      function (error) {
        call("tbankToast", {
          message: "提交失败：" + (error && error.message ? error.message : error)
        });
      }
    );
  }

  function requestExplain(button) {
    var node = state.explainNode;
    if (!node) return;
    if (!node.hidden) {
      node.hidden = true;
      button.textContent = "AI 解析";
      return;
    }
    node.hidden = false;
    button.textContent = "收起解析";
    var cacheKey = currentQuestionId();
    var cached = state.explainCache[cacheKey];
    if (cached) {
      node.innerHTML = renderAiMarkdown(cached);
      return;
    }
    if (node.getAttribute("data-loading") === "1") return;
    node.setAttribute("data-loading", "1");
    node.textContent = "AI 解析中…";
    var model = state.model;
    var verdict = state.verdict;
    var prompt = buildExplainPrompt({
      question: model.question,
      answer: model.latex || model.correctAnswer[0] || "",
      recognized: verdict ? verdict.recognized : "",
      correct: state.verdict ? recommendCorrect(state.verdict) : state.lastCorrect === true,
      score: verdict ? verdict.score : 0
    });
    call("tbankAiComplete", { prompt: prompt }).then(
      function (text) {
        var value = String(text || "").trim() || "（AI 没有给出内容）";
        state.explainCache[cacheKey] = value;
        node.innerHTML = renderAiMarkdown(value);
        node.removeAttribute("data-loading");
      },
      function (error) {
        node.textContent = "解析失败：" + (error && error.message ? error.message : error);
        node.removeAttribute("data-loading");
      }
    );
  }

  function onSubmit() {
    if (state.submitted || state.phase !== PHASES.idle) return;
    if (!state.board) return;
    if (state.board.isEmpty()) {
      call("tbankToast", { message: "还没动笔哦" });
      return;
    }
    if (state.timer) state.timer.stop();
    startGrading();
  }

  function buildGradePrompt(fields) {
    var question = String((fields && fields.question) || "");
    var answers = fields && Array.isArray(fields.correctAnswer) ? fields.correctAnswer : [];
    return [
      "你是严谨的阅卷老师，正在批改学生手写的公式默写。",
      "",
      "题目标题：" + question,
      "参考答案（以下任一写法都算正确）：" + answers.join(" | "),
      "",
      "请完成：",
      "1. 逐行识别图片中的手写字迹，按你看到的内容转写（不要纠正成你认为正确的公式）；",
      "2. 判断手写内容与参考答案是否数学等价。只看数学内容：变量顺序、括号冗余、空格、下标写法差异都不算错；系数、指数、正负号、运算符、积分上下限写错算错；",
      "3. 给出 0-10 的整数分：完全等价 10；等价但写法明显不同 8-9；主干正确但有缺项或小错 4-6；偏离题意或大面积错误 0-3；",
      "4. reason 用中文，不超过 60 字，指出关键差异（没有差异就写“与参考答案一致”）。",
      "",
      "只输出一个 JSON 对象，不要 Markdown 代码块，不要额外解释：",
      '{"recognized": "识别到的公式", "equivalent": true, "score": 10, "reason": "..."}'
    ].join("\n");
  }

  function tryParseVerdict(text) {
    var parsed;
    try {
      parsed = JSON.parse(text);
    } catch (error) {
      return null;
    }
    if (!parsed || typeof parsed !== "object") return null;
    if (typeof parsed.equivalent !== "boolean") return null;
    var score = Number(parsed.score);
    if (!isFinite(score)) return null;
    score = Math.min(10, Math.max(0, Math.round(score)));
    return {
      recognized: parsed.recognized === undefined || parsed.recognized === null ? "" : String(parsed.recognized),
      equivalent: parsed.equivalent,
      score: score,
      reason: parsed.reason === undefined || parsed.reason === null ? "" : String(parsed.reason)
    };
  }

  function parseGradingJson(text) {
    if (typeof text !== "string" || text.trim() === "") return null;
    var trimmed = text.trim();
    var candidates = [trimmed];
    var unfenced = trimmed.replace(/^```[a-zA-Z]*\s*/, "").replace(/\s*```$/, "");
    if (unfenced !== trimmed) candidates.push(unfenced);
    var block = trimmed.match(/\{[\s\S]*\}/);
    if (block) candidates.push(block[0]);
    for (var i = 0; i < candidates.length; i++) {
      var verdict = tryParseVerdict(candidates[i]);
      if (verdict) return verdict;
    }
    return null;
  }

  function recommendCorrect(verdict) {
    if (!verdict || typeof verdict !== "object") return false;
    return verdict.equivalent === true && Number(verdict.score) >= 6;
  }

  function gradeSubmission(options) {
    var board = options && options.board;
    var model = (options && options.model) || {};
    if (!board) return Promise.resolve({ ok: false, error: "画布未就绪" });
    var prompt = buildGradePrompt({ question: model.question, correctAnswer: model.correctAnswer });
    var config = state.config || {};
    var dataUrl;
    try {
      dataUrl = board.toPngDataUrl({ maxEdge: 800, crop: config.autoCrop !== false });
    } catch (error) {
      return Promise.resolve({ ok: false, error: "导出图片失败：" + (error && error.message ? error.message : error) });
    }
    return call("tbankAiComplete", { prompt: prompt, images: [dataUrl] }).then(
      function (text) {
        var verdict = parseGradingJson(text);
        if (!verdict) {
          return { ok: false, error: "AI 返回的内容无法解析为判定结果", raw: String(text || "").slice(0, 300) };
        }
        return { ok: true, verdict: verdict };
      },
      function (error) {
        return { ok: false, error: error && error.message ? error.message : String(error) };
      }
    );
  }

  function nextPhase(phase, event) {
    var table = {
      idle: { SUBMIT: "grading" },
      grading: { AI_OK: "confirm", AI_FAIL: "selfCheck" },
      confirm: { CONFIRM: "submitted" },
      selfCheck: { CONFIRM: "submitted" },
      submitted: {}
    };
    var row = table[phase];
    var next = row ? row[event] : null;
    if (!next) throw new Error("非法状态迁移：" + phase + " + " + event);
    return next;
  }

  function transition(event) {
    var next;
    try {
      next = nextPhase(state.phase, event);
    } catch (error) {
      // 最后防线：任何非法迁移都不许把页面卡死，退回自评态让用户手动判定。
      state.phase = PHASES.selfCheck;
      if (state.submitBtn) state.submitBtn.disabled = true;
      return state.phase;
    }
    state.phase = next;
    if (state.submitBtn) {
      state.submitBtn.disabled = state.phase !== PHASES.idle && state.phase !== PHASES.submitted;
    }
    return state.phase;
  }

  function submitOnce(target, correct, submit) {
    if (!target || target.submitted) return Promise.resolve(false);
    target.submitted = true;
    return Promise.resolve()
      .then(function () {
        return submit(correct);
      })
      .then(
        function () {
          return true;
        },
        function (error) {
          target.submitted = false;
          throw error;
        }
      );
  }

  function buildExplainPrompt(fields) {
    fields = fields || {};
    var question = String(fields.question || "");
    var answer = String(fields.answer || "");
    var recognized = String(fields.recognized || "（未识别）");
    var verdict = fields.correct ? "判为正确" : "判为错误";
    var score = Number(fields.score) || 0;
    return [
      "你是数学/物理老师。学生正在默写公式：" + question,
      "标准答案：" + answer,
      "学生手写识别结果：" + recognized + "（AI 判定：" + verdict + "，" + score + " 分）",
      "",
      "请用中文讲清三件事：这个公式的含义与适用条件；推导思路或记忆方法；针对学生这次写法的具体点评。数学式用 $...$（行内）与 $$...$$（独立）。总长度控制在 300 字以内。"
    ].join("\n");
  }

  function startGrading() {
    transition("SUBMIT");
    renderResult("grading");
    var epoch = state.epoch;
    var enabled = !!(state.context && state.context.aiEnabled);
    if (!enabled) {
      state.aiError = "未配置 DeepSeek 密钥，请自行对照标准答案";
      transition("AI_FAIL");
      renderResult("selfCheck");
      return;
    }
    if (!state.model.correctAnswer.length && !state.model.latex) {
      state.aiError = "本题没有标准答案，只能自评";
      transition("AI_FAIL");
      renderResult("selfCheck");
      return;
    }
    gradeSubmission({ board: state.board, model: state.model }).then(function (result) {
      if (epoch !== state.epoch || state.phase !== PHASES.grading) return; // 过期结果一律丢弃
      if (result.ok) {
        state.verdict = result.verdict;
        state.aiError = "";
        state.aiRaw = "";
        transition("AI_OK");
        renderResult("confirm");
        if (state.config && state.config.aiExplainAuto && state.explainBtn) {
          requestExplain(state.explainBtn);
        }
      } else {
        state.verdict = null;
        state.aiError = result.error;
        state.aiRaw = result.raw || "";
        transition("AI_FAIL");
        renderResult("selfCheck");
      }
    });
  }

  var pendingContext = null;
  var booted = false;
  var rootNode = null;

  function paint(model) {
    renderPage(rootNode, model);
    if (model.answered) {
      state.submitted = true;
      state.phase = PHASES.submitted;
      renderResult("submitted", state.context.wasCorrect === true);
    }
  }

  function handleContext(context) {
    state.epoch += 1;
    state.context = context && typeof context === "object" ? context : {};
    state.submitted = false;
    state.verdict = null;
    state.aiError = "";
    state.aiRaw = "";
    state.explainText = "";
    state.lastCorrect = false;
    state.lastPenTap = null;
    state.phase = PHASES.idle;
    if (state.timer) {
      state.timer.stop();
      state.timer = null;
    }
    var nextQuestion = state.context.question && typeof state.context.question === "object"
      ? state.context.question
      : {};
    var nextQuestionId = String(nextQuestion.id || "");
    if (state.board) {
      if (state.draftQuestionId === nextQuestionId) {
        state.draftStrokes = state.board.exportStrokes();
        var oldScroller = state.board.canvas.parentElement;
        if (oldScroller) {
          state.draftScrollLeft = oldScroller.scrollLeft;
          state.draftScrollTop = oldScroller.scrollTop;
        }
      } else {
        state.draftStrokes = [];
        state.draftScrollLeft = 0;
        state.draftScrollTop = 0;
      }
      state.board.dispose();
      state.board = null;
    }
    state.draftQuestionId = nextQuestionId;
    if (state.context.theme) applyTheme(state.context.theme);
    var model = normalizeContext(state.context);
    call("tbankConfigGet", {}).then(
      function (config) {
        state.config = typeof mergeConfig === "function" ? mergeConfig(config) : DEFAULT_CONFIG_FALLBACK;
        paint(model);
      },
      function () {
        state.config = DEFAULT_CONFIG_FALLBACK;
        paint(model);
      }
    );
  }

  // 入口先挂上：宿主可能在 DOMContentLoaded 之前就投递第一题，先缓存再渲染。
  globalThis.__tbankReceive = function (context) {
    if (!booted) {
      pendingContext = context;
      return;
    }
    handleContext(context);
  };

  function toggleToolFromGesture() {
    if (typeof state.applyTool !== "function") return;
    var next = state.tool === "eraser" ? "pen" : "eraser";
    state.applyTool(next);
    call("tbankToast", {
      message: next === "eraser" ? "笔杆手势：已切到橡皮" : "笔杆手势：已切回笔"
    });
  }

  // 小米焦点笔 Pro 在 Android 里把双击投递为 KeyEvent 195（194 轻捏 / 196 上滑 / 197 下滑），
  // 部分笔杆按键会以 pointerdown(button 5 / buttons bit 5) 发过来；两种都收。
  // 如果 WebView 收不到 195 键，App 侧只要转发一行：
  //   controller.runJavaScript("window.__tbankPenGesture(195)")
  globalThis.__tbankPenGesture = function (code) {
    if (Number(code) === 195) toggleToolFromGesture();
    return true;
  };

  function bindDocumentPenGesture() {
    if (state.gestureBound || typeof document === "undefined" || !document.addEventListener) return;
    state.gestureBound = true;
    document.addEventListener("keydown", function (event) {
      var code = event.keyCode || event.which;
      if (code !== 195) return;
      if (event.preventDefault) event.preventDefault();
      toggleToolFromGesture();
    });
  }

  function bindCanvasPenGesture() {
    if (!state.canvas || !state.canvas.addEventListener) return;
    if (state.canvasGestureBound) return;
    state.canvasGestureBound = true;
    state.canvas.addEventListener("pointerdown", function (event) {
      var barrel = event.button === 5 || event.button === 2 || ((event.buttons | 0) & 32) === 32;
      if (barrel) {
        if (event.preventDefault) event.preventDefault();
        toggleToolFromGesture();
        return;
      }
      // 笔杆按键收不到时，用「笔尖在同一处快速点两下」兜底
      if (event.pointerType !== "pen") return;
      var tap = { x: event.clientX, y: event.clientY, t: Date.now() };
      if (typeof isPenDoubleTap === "function" && isPenDoubleTap(state.lastPenTap, tap)) {
        state.lastPenTap = null;
        if (state.board) state.board.undoTap(2);
        toggleToolFromGesture();
        if (event.preventDefault) event.preventDefault();
        return;
      }
      state.lastPenTap = tap;
    });
  }

  function boot() {
    rootNode = document.getElementById("app");
    if (!rootNode) return;
    installBridge(globalThis);
    booted = true;
    bindDocumentPenGesture();
    document.addEventListener("visibilitychange", function () {
      if (!document.hidden) return;
      if (state.timer) state.timer.stop();
      if (state.timerLabel && !state.timerLabel.hidden) state.timerLabel.classList.add("paused");
    });
    if (pendingContext) {
      var context = pendingContext;
      pendingContext = null;
      handleContext(context);
    }
  }

  globalThis.normalizeContext = normalizeContext;
  globalThis.parseGradingJson = parseGradingJson;
  globalThis.buildGradePrompt = buildGradePrompt;
  globalThis.recommendCorrect = recommendCorrect;
  globalThis.gradeSubmission = gradeSubmission;
  globalThis.nextPhase = nextPhase;
  globalThis.submitOnce = submitOnce;
  globalThis.buildExplainPrompt = buildExplainPrompt;
  globalThis.createTimer = createTimer;
  globalThis.onTimeoutAction = onTimeoutAction;
  globalThis.renderAiMarkdown = renderAiMarkdown;

  if (typeof document !== "undefined") {
    if (document.readyState === "loading") {
      document.addEventListener("DOMContentLoaded", boot);
    } else {
      boot();
    }
  }
})();
