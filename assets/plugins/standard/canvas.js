// 手写板：指针绘制、撤销、墨迹包围盒、导出 PNG。
// 网格用 CSS 背景画（不落在 canvas 上），这样 getImageData 只统计真实笔迹。
(function () {
  "use strict";

  var BLANK_RATIO = 0.0005;
  var BLANK_PIXELS = 60;
  var INK = "#111111";
  var TOOLS = { pen: "pen", eraser: "eraser" };
  // 橡皮两种模式：pixel 只挖掉笔迹（精确），stroke 整条笔画删除
  var ERASER_MODES = { pixel: "pixel", stroke: "stroke" };
  var ERASE_TOLERANCE = 6;
  // 橡皮比笔粗一些，平板用手指/笔杆擦都不至于要反复蹭。
  var ERASER_FACTOR = 4;
  var ERASER_MIN = 18;
  // 笔事件丢失（比如笔被系统回收、WebView 吞掉 pointerup）时的兜底：这么久没笔动静就认为笔已抬起
  var PEN_IDLE_MS = 800;

  function computeInkBox(alpha, width, height) {
    var minX = width;
    var minY = height;
    var maxX = -1;
    var maxY = -1;
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        if (alpha[(y * width + x) * 4 + 3] > 0) {
          if (x < minX) minX = x;
          if (x > maxX) maxX = x;
          if (y < minY) minY = y;
          if (y > maxY) maxY = y;
        }
      }
    }
    if (maxX < 0) return null;
    return { x: minX, y: minY, w: maxX - minX + 1, h: maxY - minY + 1 };
  }

  function shouldRejectBlank(inkRatio) {
    return !(inkRatio >= BLANK_RATIO);
  }

  function distanceToSegment(px, py, ax, ay, bx, by) {
    var dx = bx - ax;
    var dy = by - ay;
    if (dx === 0 && dy === 0) return Math.hypot(px - ax, py - ay);
    var t = ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy);
    t = Math.max(0, Math.min(1, t));
    return Math.hypot(px - (ax + t * dx), py - (ay + t * dy));
  }

  // 笔杆按键收不到时的兜底：笔尖在同一处快速点两下。
  // maxGapMs 由调用方传入（App 设置里的「笔尖双击间隔」），默认 320ms。
  function isPenDoubleTap(previous, current, maxGapMs) {
    if (!previous || !current) return false;
    var limit = Number(maxGapMs);
    if (!isFinite(limit) || limit <= 0) limit = 320;
    var gap = Number(current.t) - Number(previous.t);
    if (!isFinite(gap) || gap < 0 || gap > limit) return false;
    // 间隔越大，允许的落点漂移也该放宽一点，否则慢速双击很难命中。
    var distanceLimit = Math.max(14, Math.min(28, 14 + (limit - 320) / 20));
    var distance = Math.hypot(current.x - previous.x, current.y - previous.y);
    return distance <= distanceLimit;
  }

  function hitStroke(stroke, point, tolerance) {
    if (!stroke || !stroke.points || stroke.points.length === 0) return false;
    var limit = (stroke.width || 1) / 2 + (tolerance || 0);
    var points = stroke.points;
    if (points.length === 1) {
      return Math.hypot(point.x - points[0].x, point.y - points[0].y) <= limit;
    }
    for (var i = 1; i < points.length; i++) {
      var a = points[i - 1];
      var b = points[i];
      if (distanceToSegment(point.x, point.y, a.x, a.y, b.x, b.y) <= limit) return true;
    }
    return false;
  }

  function DrawBoard(canvasEl, options) {
    options = options || {};
    this.canvas = canvasEl;
    this.ctx = canvasEl.getContext("2d");
    this.penWidth = typeof options.penWidth === "number" ? options.penWidth : 3;
    this.tool = options.tool === TOOLS.eraser ? TOOLS.eraser : TOOLS.pen;
    this.eraserWidth = typeof options.eraserWidth === "number"
      ? options.eraserWidth
      : Math.max(ERASER_MIN, this.penWidth * ERASER_FACTOR);
    this.eraserMode = options.eraserMode === ERASER_MODES.stroke ? ERASER_MODES.stroke : ERASER_MODES.pixel;
    this.grid = options.grid !== false;
    // 笔尖双击判定间隔，App 设置里可调；0 或非法值退回 320ms。
    this.doubleTapMs = Number(options.doubleTapMs) > 0 ? Number(options.doubleTapMs) : 320;
    // 手势回调：手势触发时通知上层切换笔/橡皮，参数为 'toggle'。
    this.onGesture = typeof options.onGesture === "function" ? options.onGesture : null;
    // 只认手写笔：开启后手指 / 鼠标触摸都不落笔，只能用笔（或笔的橡皮端）。
    this.penOnly = options.penOnly === true;
    this.strokes = [];
    this.undoStack = [];
    this.current = null;
    this.activePointerId = null;
    // 笔尖双击的第一击：只记录时间和位置，不落笔。
    this.lastPenTap = null;
    // 笔杆按键 / 橡皮位按下时，后续 move/up 都属于手势，不画。
    this.gesturePointerId = null;
    // 用笔写字时手掌先落下的那一坨触摸要忽略掉。
    this.penActive = false;
    this.penLastAt = 0;
    this.dpr = 1;
    this.cssWidth = 0;
    this.cssHeight = 0;
    this.observer = null;
    this._down = this._onDown.bind(this);
    this._move = this._onMove.bind(this);
    this._up = this._onUp.bind(this);
  }

  DrawBoard.prototype.mount = function () {
    var self = this;
    if (typeof ResizeObserver !== "undefined" && this.canvas.parentElement) {
      this.observer = new ResizeObserver(function () {
        self.resize();
      });
      this.observer.observe(this.canvas.parentElement);
    }
    this.canvas.addEventListener("pointerdown", this._down);
    this.canvas.addEventListener("pointermove", this._move);
    this.canvas.addEventListener("pointerup", this._up);
    this.canvas.addEventListener("pointercancel", this._up);
    this.setGrid(this.grid);
    this.setTool(this.tool);
    this.resize();
    return this;
  };

  DrawBoard.prototype.setGrid = function (on) {
    this.grid = !!on;
    if (this.canvas.classList) this.canvas.classList.toggle("has-grid", this.grid);
  };

  DrawBoard.prototype.setPenWidth = function (width) {
    var value = Number(width);
    if (!isFinite(value)) value = 3;
    this.penWidth = Math.max(1, Math.min(20, value));
    if (this.tool === TOOLS.eraser) {
      this.eraserWidth = Math.max(ERASER_MIN, this.penWidth * ERASER_FACTOR);
    }
  };

  DrawBoard.prototype.setTool = function (tool) {
    this.tool = tool === TOOLS.eraser ? TOOLS.eraser : TOOLS.pen;
    this.current = null;
    this.activePointerId = null;
    this.lastPenTap = null;
    if (this.canvas.classList) this.canvas.classList.toggle("is-eraser", this.tool === TOOLS.eraser);
    return this.tool;
  };

  DrawBoard.prototype.setEraserMode = function (mode) {
    this.eraserMode = mode === ERASER_MODES.stroke ? ERASER_MODES.stroke : ERASER_MODES.pixel;
    return this.eraserMode;
  };

  // 开关「只认手写笔」。切换时打断当前笔画，避免半截线留在画布上。
  DrawBoard.prototype.setPenOnly = function (value) {
    this.penOnly = !!value;
    this.current = null;
    this.activePointerId = null;
    this.gesturePointerId = null;
    this.lastPenTap = null;
    return this.penOnly;
  };

  DrawBoard.prototype._eraseStrokeAt = function (point) {
    for (var i = this.strokes.length - 1; i >= 0; i--) {
      var stroke = this.strokes[i];
      if (stroke.tool === TOOLS.eraser) continue;
      if (hitStroke(stroke, point, ERASE_TOLERANCE)) {
        var removed = this.strokes.splice(i, 1)[0];
        this.undoStack.push({ type: "erase", stroke: removed, index: i });
        this._redraw();
        return true;
      }
    }
    return false;
  };

  DrawBoard.prototype.setEraserWidth = function (width) {
    var value = Number(width);
    if (!isFinite(value)) return;
    this.eraserWidth = Math.max(ERASER_MIN / 2, Math.min(80, value));
  };

  DrawBoard.prototype.resize = function () {
    // 画布固定为滚动容器的 2 倍；用显式像素尺寸兜底，
    // 避免部分 WebView 对 `height: 200%` 解析成 auto，导致没有纵向滚动条。
    var parent = this.canvas.parentElement;
    if (parent && parent.clientWidth > 0 && parent.clientHeight > 0) {
      var wantWidth = Math.round(parent.clientWidth * 2);
      var wantHeight = Math.round(parent.clientHeight * 2);
      var wantWidthCss = wantWidth + "px";
      var wantHeightCss = wantHeight + "px";
      if (this.canvas.style.width !== wantWidthCss) this.canvas.style.width = wantWidthCss;
      if (this.canvas.style.height !== wantHeightCss) this.canvas.style.height = wantHeightCss;
    }
    var rect = this.canvas.getBoundingClientRect();
    var dpr = (typeof window !== "undefined" && window.devicePixelRatio) || 1;
    var width = Math.max(1, Math.round(rect.width));
    var height = Math.max(1, Math.round(rect.height));
    if (width === this.cssWidth && height === this.cssHeight && dpr === this.dpr) return;
    this.cssWidth = width;
    this.cssHeight = height;
    this.dpr = dpr;
    this.canvas.width = Math.round(width * dpr);
    this.canvas.height = Math.round(height * dpr);
    this._redraw();
  };

  DrawBoard.prototype._point = function (event) {
    var rect = this.canvas.getBoundingClientRect();
    return {
      x: event.clientX - rect.left,
      y: event.clientY - rect.top,
      p: pressureOf(event)
    };
  };

  function pressureOf(event) {
    if (!event || event.pointerType !== "pen") return 0;
    var value = Number(event.pressure);
    // 部分笔/驱动把不支持压感上报成 0，按中性值兜底，避免笔宽突然掉到最细。
    if (!isFinite(value) || value <= 0) return 0.5;
    return Math.min(1, Math.max(0.05, value));
  }

  DrawBoard.prototype._widthOf = function (stroke, pressure) {
    if (stroke.tool === TOOLS.eraser) return stroke.width;
    if (!pressure) return stroke.width;
    return Math.max(0.8, stroke.width * (0.55 + 0.85 * pressure));
  };

  DrawBoard.prototype.setDoubleTapMs = function (value) {
    var num = Number(value);
    if (!isFinite(num) || num <= 0) return this.doubleTapMs;
    this.doubleTapMs = Math.max(120, Math.min(1200, Math.round(num)));
    return this.doubleTapMs;
  };

  DrawBoard.prototype._emitGesture = function () {
    if (!this.onGesture) return;
    try {
      this.onGesture("toggle");
    } catch (error) {
      /* 回调异常不影响绘制 */
    }
  };

  DrawBoard.prototype._onDown = function (event) {
    if (this.current) return;

    var type = event.pointerType || "mouse";
    // 设置里打开「手写板屏蔽手指」后，只有手写笔（含 Android 14 把
    // TOOL_TYPE_ERASER 映射成的 'eraser'）能落笔。这里刻意不调用
    // preventDefault，手指仍然可以拖动页面滚动画布区域。
    if (this.penOnly && type !== "pen" && type !== "eraser") return;

    // 笔杆按键（barrel，button 5 / buttons bit 5）、鼠标右键、侧键：
    // 这是「切笔/橡皮」手势，不落笔。
    if (event.button === 5 || event.button === 2 || ((event.buttons | 0) & 32) === 32) {
      if (event.pointerId !== undefined) {
        this.activePointerId = event.pointerId;
        this.gesturePointerId = event.pointerId;
        if (this.canvas.setPointerCapture) {
          try {
            this.canvas.setPointerCapture(event.pointerId);
          } catch (error) {
            /* 忽略 */
          }
        }
      } else {
        this.gesturePointerId = -1;
      }
      this._emitGesture();
      if (event.preventDefault) event.preventDefault();
      return;
    }

    if (this.tool === TOOLS.eraser && this.eraserMode === ERASER_MODES.stroke) {
      if (event.pointerId !== undefined) this.activePointerId = event.pointerId;
      if (this.canvas.setPointerCapture) {
        try {
          this.canvas.setPointerCapture(event.pointerId);
        } catch (error) {
          /* 忽略 */
        }
      }
      this._eraseStrokeAt(this._point(event));
      if (event.preventDefault) event.preventDefault();
      return;
    }

    if (type === "mouse" && event.button !== 0) return;
    // 笔正在写的时候，手掌的触摸一律无视
    if (type === "touch" && this.penActive) {
      if (this.current) return;
      var idle = typeof Date !== "undefined" && this.penLastAt
        ? Date.now() - this.penLastAt
        : PEN_IDLE_MS;
      if (idle < PEN_IDLE_MS) return;
      this.penActive = false;
    }
    if (type === "pen") {
      this.penActive = true;
      this.penLastAt = Date.now();

      // 小米焦点笔 Pro 的双击（以及部分笔杆按键收不到时的兜底）：
      // 笔尖在同一处快速点两下，命中就切工具、不落笔。
      var tapPoint = this._point(event);
      var tap = { x: tapPoint.x, y: tapPoint.y, t: Date.now() };
      if (isPenDoubleTap(this.lastPenTap, tap, this.doubleTapMs)) {
        this.lastPenTap = null;
        this.undoTap(2);
        this._emitGesture();
        if (event.preventDefault) event.preventDefault();
        return;
      }
      this.lastPenTap = tap;
    }

    if (event.pointerId !== undefined) this.activePointerId = event.pointerId;
    if (this.canvas.setPointerCapture) {
      try {
        this.canvas.setPointerCapture(event.pointerId);
      } catch (error) {
        /* 某些 WebView 不支持，忽略 */
      }
    }

    // Android 14+ 的 TOOL_TYPE_ERASER 会映射成 pointerType 'eraser'：
    // 当前工具不变，这一笔按橡皮落。
    var forcedEraser = type === "eraser";
    var useEraser = forcedEraser || this.tool === TOOLS.eraser;
    var stroke = {
      tool: useEraser ? TOOLS.eraser : TOOLS.pen,
      width: useEraser ? this.eraserWidth : this.penWidth,
      points: [this._point(event)]
    };
    this.strokes.push(stroke);
    this.current = stroke;
    this._drawSegment(stroke, stroke.points[0], stroke.points[0]);
    if (event.preventDefault) event.preventDefault();
  };

  DrawBoard.prototype._onMove = function (event) {
    // 笔杆按键手势按住期间的所有 move 都吞掉，避免手势滑动时留下墨迹。
    if (this.gesturePointerId !== null) {
      if (event.pointerId === undefined || event.pointerId === this.gesturePointerId) {
        if (event.preventDefault) event.preventDefault();
        return;
      }
    }
    if (this.tool === TOOLS.eraser && this.eraserMode === ERASER_MODES.stroke && !this.current) {
      if (this.activePointerId === null) return;
      if (event.pointerId !== undefined && event.pointerId !== this.activePointerId) return;
      this._eraseStrokeAt(this._point(event));
      if (event.preventDefault) event.preventDefault();
      return;
    }
    if (!this.current) return;
    if (event.pointerType === "pen") this.penLastAt = Date.now();
    if (event.pointerId !== undefined && this.activePointerId !== null && event.pointerId !== this.activePointerId) {
      return;
    }
    // 手写笔一次 pointermove 里可能压着好几个采样点，全收下来才跟手
    var list = null;
    if (typeof event.getCoalescedEvents === "function") {
      try {
        list = event.getCoalescedEvents();
      } catch (error) {
        list = null;
      }
    }
    if (!list || !list.length) list = [event];
    var points = this.current.points;
    for (var i = 0; i < list.length; i++) {
      var point = this._point(list[i]);
      var previous = points[points.length - 1];
      if (Math.abs(point.x - previous.x) < 0.4 && Math.abs(point.y - previous.y) < 0.4) continue;
      points.push(point);
      this._drawSegment(this.current, previous, point);
    }
    if (event.preventDefault) event.preventDefault();
  };

  DrawBoard.prototype._onUp = function (event) {
    if (this.gesturePointerId !== null) {
      if (event && event.pointerId !== undefined && event.pointerId !== this.gesturePointerId) {
        return;
      }
      this.gesturePointerId = null;
      this.activePointerId = null;
      this.lastPenTap = null;
      if (this.canvas.releasePointerCapture && event && event.pointerId !== undefined) {
        try {
          this.canvas.releasePointerCapture(event.pointerId);
        } catch (error) {
          /* 忽略 */
        }
      }
      if (event && event.preventDefault) event.preventDefault();
      return;
    }
    if (!this.current) {
      if (this.activePointerId !== null && (!event || event.pointerId === undefined || event.pointerId === this.activePointerId)) {
        this.activePointerId = null;
      }
      return;
    }
    if (event && event.pointerId !== undefined && this.activePointerId !== null && event.pointerId !== this.activePointerId) {
      return;
    }
    if (event && event.pointerType === "pen") {
      this.penActive = false;
      this.penLastAt = Date.now();
    }
    this.current = null;
    this.activePointerId = null;
    if (this.canvas.releasePointerCapture && event && event.pointerId !== undefined) {
      try {
        this.canvas.releasePointerCapture(event.pointerId);
      } catch (error) {
        /* 忽略 */
      }
    }
    if (event && event.preventDefault) event.preventDefault();
  };

  DrawBoard.prototype._redraw = function () {
    var ctx = this.ctx;
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, this.canvas.width, this.canvas.height);
    ctx.setTransform(this.dpr, 0, 0, this.dpr, 0, 0);
    for (var i = 0; i < this.strokes.length; i++) this._drawStroke(this.strokes[i]);
  };

  DrawBoard.prototype._drawSegment = function (stroke, from, to) {
    var ctx = this.ctx;
    var erasing = stroke.tool === TOOLS.eraser;
    ctx.save();
    // 橡皮按像素擦：destination-out 把落笔处的墨迹抠掉，重绘时照样按顺序还原
    ctx.globalCompositeOperation = erasing ? "destination-out" : "source-over";
    ctx.strokeStyle = INK;
    ctx.fillStyle = INK;
    ctx.lineCap = "round";
    ctx.lineJoin = "round";
    if (from === to) {
      ctx.beginPath();
      ctx.arc(to.x, to.y, Math.max(0.6, this._widthOf(stroke, to.p) / 2), 0, Math.PI * 2);
      ctx.fill();
    } else {
      ctx.beginPath();
      ctx.lineWidth = this._widthOf(stroke, (from.p + to.p) / 2);
      ctx.moveTo(from.x, from.y);
      ctx.lineTo(to.x, to.y);
      ctx.stroke();
    }
    ctx.restore();
  };

  DrawBoard.prototype._drawStroke = function (stroke) {
    var points = stroke.points;
    if (!points || points.length === 0) return;
    if (points.length === 1) {
      this._drawSegment(stroke, points[0], points[0]);
      return;
    }
    for (var i = 1; i < points.length; i++) this._drawSegment(stroke, points[i - 1], points[i]);
  };

  DrawBoard.prototype.undo = function () {
    if (this.undoStack.length > 0) {
      var action = this.undoStack.pop();
      if (action && action.type === "erase") {
        this.strokes.splice(Math.min(action.index, this.strokes.length), 0, action.stroke);
        this.current = null;
        this.activePointerId = null;
        this._redraw();
        return true;
      }
    }
    if (this.strokes.length === 0) return false;
    this.strokes.pop();
    this.current = null;
    this.activePointerId = null;
    this._redraw();
    return true;
  };

  // 只撤销"单点"笔画，避免双击兜底误伤真正写的字
  DrawBoard.prototype.undoTap = function (count) {
    var limit = Number(count) > 0 ? Math.floor(Number(count)) : 1;
    var removed = 0;
    while (removed < limit && this.strokes.length > 0) {
      var last = this.strokes[this.strokes.length - 1];
      if (!last.points || last.points.length !== 1) break;
      this.strokes.pop();
      removed += 1;
    }
    if (removed > 0) {
      this.current = null;
      this.activePointerId = null;
      this._redraw();
    }
    return removed;
  };

  DrawBoard.prototype.clear = function () {
    this.strokes = [];
    this.current = null;
    this.activePointerId = null;
    this._redraw();
  };

  // 旋转屏幕/重建 DOM 时用来保留笔迹。
  DrawBoard.prototype.exportStrokes = function () {
    return this.strokes.map(function (stroke) {
      return {
        tool: stroke.tool,
        width: stroke.width,
        points: stroke.points.map(function (point) {
          return { x: point.x, y: point.y, p: point.p };
        })
      };
    });
  };

  DrawBoard.prototype.importStrokes = function (strokes) {
    if (!Array.isArray(strokes)) return;
    this.strokes = strokes.map(function (stroke) {
      return {
        tool: stroke.tool,
        width: stroke.width,
        points: (stroke.points || []).map(function (point) {
          return { x: point.x, y: point.y, p: point.p };
        })
      };
    });
    this.current = null;
    this.activePointerId = null;
    this.undoStack = [];
    this._redraw();
  };

  DrawBoard.prototype.inkStats = function () {
    var width = this.canvas.width;
    var height = this.canvas.height;
    if (!width || !height) return { pixels: 0, ratio: 0 };
    var data = this.ctx.getImageData(0, 0, width, height).data;
    var ink = 0;
    for (var i = 3; i < data.length; i += 4) {
      if (data[i] > 0) ink++;
    }
    return { pixels: ink, ratio: ink / (width * height) };
  };

  DrawBoard.prototype.inkRatio = function () {
    return this.inkStats().ratio;
  };

  DrawBoard.prototype.isEmpty = function () {
    var stats = this.inkStats();
    return stats.pixels < BLANK_PIXELS || shouldRejectBlank(stats.ratio);
  };

  DrawBoard.prototype.toPngDataUrl = function (options) {
    options = options || {};
    var maxEdge = options.maxEdge || 800;
    var crop = options.crop !== false;
    var margin = Math.round(8 * this.dpr);
    var box = { x: 0, y: 0, w: this.canvas.width, h: this.canvas.height };
    if (crop) {
      var image = this.ctx.getImageData(0, 0, this.canvas.width, this.canvas.height);
      var inkBox = computeInkBox(image.data, this.canvas.width, this.canvas.height);
      if (inkBox) box = inkBox;
    }
    var sx = Math.max(0, box.x - margin);
    var sy = Math.max(0, box.y - margin);
    var sw = Math.min(this.canvas.width - sx, box.w + margin * 2);
    var sh = Math.min(this.canvas.height - sy, box.h + margin * 2);
    var scale = Math.min(1, maxEdge / Math.max(sw, sh));
    var out = document.createElement("canvas");
    out.width = Math.max(1, Math.round(sw * scale));
    out.height = Math.max(1, Math.round(sh * scale));
    var octx = out.getContext("2d");
    octx.fillStyle = "#ffffff";
    octx.fillRect(0, 0, out.width, out.height);
    octx.drawImage(this.canvas, sx, sy, sw, sh, 0, 0, out.width, out.height);
    return out.toDataURL("image/png");
  };

  DrawBoard.prototype.dispose = function () {
    this.canvas.removeEventListener("pointerdown", this._down);
    this.canvas.removeEventListener("pointermove", this._move);
    this.canvas.removeEventListener("pointerup", this._up);
    this.canvas.removeEventListener("pointercancel", this._up);
    this.current = null;
    this.activePointerId = null;
    this.penActive = false;
    if (this.observer) {
      this.observer.disconnect();
      this.observer = null;
    }
  };

  globalThis.computeInkBox = computeInkBox;
  globalThis.shouldRejectBlank = shouldRejectBlank;
  globalThis.distanceToSegment = distanceToSegment;
  globalThis.hitStroke = hitStroke;
  globalThis.isPenDoubleTap = isPenDoubleTap;
  globalThis.DrawBoard = DrawBoard;
  globalThis.DRAW_TOOLS = TOOLS;
  globalThis.DRAW_ERASER_MODES = ERASER_MODES;
})();
