// 轻量公式排版：把常用的 LaTeX 子集转成 HTML。
// 不依赖任何第三方库，认不出的命令原样保留，绝不让整段公式消失。
(function () {
  "use strict";

  var GREEK = {
    alpha: "α", beta: "β", gamma: "γ", delta: "δ", epsilon: "ε", varepsilon: "ε",
    zeta: "ζ", eta: "η", theta: "θ", vartheta: "ϑ", iota: "ι", kappa: "κ",
    lambda: "λ", mu: "μ", nu: "ν", xi: "ξ", omicron: "ο", pi: "π", varpi: "ϖ",
    rho: "ρ", varrho: "ϱ", sigma: "σ", varsigma: "ς", tau: "τ", upsilon: "υ",
    phi: "φ", varphi: "ϕ", chi: "χ", psi: "ψ", omega: "ω",
    Gamma: "Γ", Delta: "Δ", Theta: "Θ", Lambda: "Λ", Xi: "Ξ", Pi: "Π",
    Sigma: "Σ", Upsilon: "Υ", Phi: "Φ", Psi: "Ψ", Omega: "Ω"
  };

  var SYMBOLS = {
    times: "×", cdot: "·", pm: "±", mp: "∓", le: "≤", leq: "≤", ge: "≥", geq: "≥",
    ne: "≠", neq: "≠", approx: "≈", equiv: "≡", sim: "∼", simeq: "≃",
    infty: "∞", partial: "∂", nabla: "∇", to: "→", rightarrow: "→", leftarrow: "←",
    Rightarrow: "⇒", Leftarrow: "⇐", leftrightarrow: "↔", Leftrightarrow: "⇔",
    degree: "°", angle: "∠", perp: "⊥", parallel: "∥", propto: "∝",
    therefore: "∴", because: "∵", cdots: "⋯", ldots: "…", dots: "…",
    prime: "′", circ: "∘", ast: "∗", star: "⋆", bullet: "•", mid: "|", Vert: "‖",
    cup: "∪", cap: "∩", subset: "⊂", supset: "⊃", subseteq: "⊆", supseteq: "⊇",
    in: "∈", notin: "∉", forall: "∀", exists: "∃", emptyset: "∅", varnothing: "∅",
    sum: "∑", prod: "∏", coprod: "∐", int: "∫", iint: "∬", iiint: "∭", oint: "∮",
    lim: "lim", log: "log", ln: "ln", lg: "lg", sin: "sin", cos: "cos", tan: "tan",
    cot: "cot", sec: "sec", csc: "csc", arcsin: "arcsin", arccos: "arccos", arctan: "arctan",
    exp: "exp", max: "max", min: "min", sup: "sup", inf: "inf", det: "det", gcd: "gcd",
    lfloor: "⌊", rfloor: "⌋", lceil: "⌈", rceil: "⌉", langle: "⟨", rangle: "⟩",
    hbar: "ℏ", ell: "ℓ", Re: "ℜ", Im: "ℑ", aleph: "ℵ",
    quad: " ", qquad: "  "
  };

  var SPACES = { ",": "", ";": "", ":": "", "!": "", " ": "", ">": " " };

  var ACCENTS = { vec: "\u20d7", hat: "\u0302", bar: "\u0304", dot: "\u0307", tilde: "\u0303" };

  function escapeHtml(text) {
    return String(text)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#39;");
  }

  function readGroup(s, start) {
    var i = start;
    while (i < s.length && s[i] === " ") i++;
    if (i >= s.length) return { text: "", end: i };
    if (s[i] !== "{") {
      if (s[i] === "\\") {
        var j = i + 1;
        var k = j;
        while (k < s.length && /[a-zA-Z]/.test(s[k])) k++;
        if (k === j) return { text: s[i + 1] || "", end: Math.min(i + 2, s.length) };
        return { text: s.slice(i, k), end: k };
      }
      return { text: s[i], end: i + 1 };
    }
    var depth = 0;
    var j2 = i;
    for (; j2 < s.length; j2++) {
      if (s[j2] === "{") depth++;
      else if (s[j2] === "}") {
        depth--;
        if (depth === 0) break;
      }
    }
    return { text: s.slice(i + 1, j2), end: Math.min(j2 + 1, s.length) };
  }

  var DEPTH = 0;
  var MAX_DEPTH = 40;

  function render(s) {
    if (DEPTH >= MAX_DEPTH) return escapeHtml(s);
    DEPTH += 1;
    try {
      return renderBody(s);
    } finally {
      DEPTH -= 1;
    }
  }

  function renderBody(s) {
    var out = "";
    var i = 0;
    while (i < s.length) {
      var c = s[i];
      if (c === "\\") {
        var j = i + 1;
        while (j < s.length && /[a-zA-Z]/.test(s[j])) j++;
        var name = s.slice(i + 1, j);
        if (name.length === 0) {
          var ch = s[j] || "";
          if (Object.prototype.hasOwnProperty.call(SPACES, ch)) {
            out += SPACES[ch];
            i = j + 1;
            continue;
          }
          out += escapeHtml(ch);
          i = j + 1;
          continue;
        }
        i = j;
        if (name === "frac" || name === "dfrac" || name === "tfrac") {
          var num = readGroup(s, i);
          var den = readGroup(s, num.end);
          out += '<span class="frac"><span class="num">' + render(num.text) +
            '</span><span class="den">' + render(den.text) + "</span></span>";
          i = den.end;
          continue;
        }
        if (name === "sqrt") {
          var inner = readGroup(s, i);
          out += '<span class="sqrt"><span class="radic">√</span><span class="inner">' +
            render(inner.text) + "</span></span>";
          i = inner.end;
          continue;
        }
        if (name === "left" || name === "right") {
          var k2 = i;
          while (k2 < s.length && s[k2] === " ") k2++;
          if (k2 >= s.length) {
            i = k2;
            continue;
          }
          if (s[k2] === ".") {
            i = k2 + 1;
            continue;
          }
          if (s[k2] === "\\") {
            var m = k2 + 1;
            while (m < s.length && /[a-zA-Z]/.test(s[m])) m++;
            if (m === k2 + 1) {
              out += escapeHtml(s[k2 + 1] || "");
              i = k2 + 2;
            } else {
              var sub = s.slice(k2 + 1, m);
              out += SYMBOLS[sub] || GREEK[sub] || ("(" + sub + ")");
              i = m;
            }
            continue;
          }
          if (s[k2] === "{") out += "(";
          else if (s[k2] === "}") out += ")";
          else out += escapeHtml(s[k2]);
          i = k2 + 1;
          continue;
        }
        if (Object.prototype.hasOwnProperty.call(ACCENTS, name)) {
          var g = readGroup(s, i);
          var mark = ACCENTS[name];
          out += '<span class="accent">' + render(g.text) +
            '<span class="accent-mark">' + mark + "</span></span>";
          i = g.end;
          continue;
        }
        if (name === "text" || name === "mathrm" || name === "operatorname" || name === "mathbf") {
          var textGroup = readGroup(s, i);
          out += '<span class="tex-text' + (name === "text" ? "" : " tex-" + name) + '">' +
            escapeHtml(textGroup.text) + "</span>";
          i = textGroup.end;
          continue;
        }
        if (name === "overline" || name === "underline" || name === "boxed") {
          var boxGroup = readGroup(s, i);
          out += '<span class="tex-' + name + '">' + render(boxGroup.text) + "</span>";
          i = boxGroup.end;
          continue;
        }
        if (Object.prototype.hasOwnProperty.call(GREEK, name)) {
          out += GREEK[name];
          continue;
        }
        if (Object.prototype.hasOwnProperty.call(SYMBOLS, name)) {
          out += SYMBOLS[name];
          continue;
        }
        out += "\\" + name;
        continue;
      }
      if (c === "^" || c === "_") {
        var grp = readGroup(s, i + 1);
        var tag = c === "^" ? "sup" : "sub";
        out += "<" + tag + ">" + render(grp.text) + "</" + tag + ">";
        i = grp.end;
        continue;
      }
      if (c === "{") {
        if (s.indexOf("}", i) === -1) {
          out += "{";
          i += 1;
          continue;
        }
        var gg = readGroup(s, i);
        out += render(gg.text);
        i = gg.end;
        continue;
      }
      if (c === "}") {
        i++;
        continue;
      }
      out += c;
      i++;
    }
    return out;
  }

  function plain(s) {
    if (DEPTH >= MAX_DEPTH) return String(s);
    DEPTH += 1;
    try {
      return plainBody(s);
    } finally {
      DEPTH -= 1;
    }
  }

  function plainBody(s) {
    var out = "";
    var i = 0;
    while (i < s.length) {
      var c = s[i];
      if (c === "\\") {
        var j = i + 1;
        while (j < s.length && /[a-zA-Z]/.test(s[j])) j++;
        var name = s.slice(i + 1, j);
        if (name.length === 0) {
          var ch = s[j] || "";
          out += Object.prototype.hasOwnProperty.call(SPACES, ch) ? SPACES[ch] : ch;
          i = j + 1;
          continue;
        }
        i = j;
        if (name === "frac" || name === "dfrac" || name === "tfrac") {
          var num = readGroup(s, i);
          var den = readGroup(s, num.end);
          out += plain(num.text) + "/" + plain(den.text);
          i = den.end;
          continue;
        }
        if (name === "sqrt") {
          var inner = readGroup(s, i);
          out += "√(" + plain(inner.text) + ")";
          i = inner.end;
          continue;
        }
        if (name === "left" || name === "right") {
          var k2 = i;
          while (k2 < s.length && s[k2] === " ") k2++;
          if (k2 >= s.length) { i = k2; continue; }
          if (s[k2] === ".") { i = k2 + 1; continue; }
          if (s[k2] === "\\") {
            var m = k2 + 1;
            while (m < s.length && /[a-zA-Z]/.test(s[m])) m++;
            out += m === k2 + 1 ? (s[k2 + 1] || "") : (SYMBOLS[s.slice(k2 + 1, m)] || "");
            i = m === k2 + 1 ? k2 + 2 : m;
            continue;
          }
          i = k2 + 1;
          continue;
        }
        if (Object.prototype.hasOwnProperty.call(ACCENTS, name)) {
          var g = readGroup(s, i);
          out += plain(g.text);
          i = g.end;
          continue;
        }
        if (name === "text" || name === "mathrm" || name === "operatorname" || name === "mathbf") {
          var textGroup = readGroup(s, i);
          out += plain(textGroup.text);
          i = textGroup.end;
          continue;
        }
        if (name === "overline" || name === "underline" || name === "boxed") {
          var boxGroup = readGroup(s, i);
          out += plain(boxGroup.text);
          i = boxGroup.end;
          continue;
        }
        if (Object.prototype.hasOwnProperty.call(GREEK, name)) { out += GREEK[name]; continue; }
        if (Object.prototype.hasOwnProperty.call(SYMBOLS, name)) { out += SYMBOLS[name]; continue; }
        out += name;
        continue;
      }
      if (c === "^" || c === "_") {
        var grp = readGroup(s, i + 1);
        out += plain(grp.text);
        i = grp.end;
        continue;
      }
      if (c === "{" || c === "}") { i++; continue; }
      out += c;
      i++;
    }
    return out;
  }

  function renderMath(source, display) {
    var value = String(source === undefined || source === null ? "" : source).trim();
    if (!value) return "";
    var engine = typeof globalThis !== "undefined" ? globalThis.katex : null;
    if (engine && typeof engine.renderToString === "function") {
      try {
        return engine.renderToString(value, {
          displayMode: !!display,
          throwOnError: false,
          strict: false,
          output: "html"
        });
      } catch (error) {
        // KaTeX 解析失败时退回轻量排版，保证公式仍可见
      }
    }
    return render(escapeHtml(value));
  }

  function renderTex(source) {
    if (!source) return "";
    return renderMath(source, false);
  }

  // 题干、提示、解析里常把公式混在中文句子里，形如：
  //   写出函数 $f(x)$ 在点 $x_0$ 处的导数
  // 这里把 $...$ / $$...$$ / \(...\) / \[...\] 切出来交给 KaTeX，正文保持转义后的纯文本。
  // 落单的 $（如「价格 $5 元」）不动，避免把正文吃掉。
  var RICH = /\$\$([\s\S]+?)\$\$|\\\[([\s\S]+?)\\\]|\$([^$\n]+?)\$|\\\(([\s\S]+?)\\\)/g;

  function renderRich(text) {
    var source = text === undefined || text === null ? "" : String(text);
    if (source === "") return "";
    var out = "";
    var last = 0;
    var match;
    RICH.lastIndex = 0;
    while ((match = RICH.exec(source)) !== null) {
      if (match.index > last) out += escapeHtml(source.slice(last, match.index));
      var isDisplay = match[1] !== undefined || match[2] !== undefined;
      var body;
      if (match[1] !== undefined) body = match[1];
      else if (match[2] !== undefined) body = match[2];
      else if (match[3] !== undefined) body = match[3];
      else body = match[4];
      out += '<span class="' + (isDisplay ? "tex-display" : "tex-inline") + '">' +
        renderMath(body, isDisplay) + "</span>";
      last = match.index + match[0].length;
    }
    out += escapeHtml(source.slice(last));
    return out;
  }

  function texToPlain(source) {
    if (!source) return "";
    return plain(String(source).trim());
  }

  globalThis.renderTex = renderTex;
  globalThis.renderRich = renderRich;
  globalThis.texToPlain = texToPlain;
})();
