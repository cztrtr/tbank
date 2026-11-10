// 宿主通信：统一 Android(TBankChannel) 与 Windows(chrome.webview) 两种通道。
(function () {
  "use strict";

  var pending = new Map();
  var seq = 0;
  var channel = null;
  var TIMEOUT_MS = 120000;
  var hasTimer = typeof setTimeout === "function";

  function installBridge(win) {
    win = win || globalThis;
    win.__tbankResolve = function (id, result) {
      var entry = pending.get(String(id));
      if (!entry) return;
      pending.delete(String(id));
      if (entry.timer && typeof clearTimeout === "function") clearTimeout(entry.timer);
      entry.resolve(result);
    };
    win.__tbankReject = function (id, message) {
      var entry = pending.get(String(id));
      if (!entry) return;
      pending.delete(String(id));
      if (entry.timer && typeof clearTimeout === "function") clearTimeout(entry.timer);
      entry.reject(new Error(String(message || "宿主返回错误")));
    };

    if (win.TBankChannel && typeof win.TBankChannel.postMessage === "function") {
      channel = {
        kind: "android",
        send: function (payload) {
          win.TBankChannel.postMessage(payload);
        }
      };
    } else if (
      win.chrome &&
      win.chrome.webview &&
      typeof win.chrome.webview.postMessage === "function"
    ) {
      channel = {
        kind: "windows",
        send: function (payload) {
          win.chrome.webview.postMessage(payload);
        }
      };
    } else {
      channel = null;
    }
    return channel ? channel.kind : null;
  }

  function call(name, args) {
    return new Promise(function (resolve, reject) {
      if (!channel) {
        reject(new Error("宿主未连接"));
        return;
      }
      seq += 1;
      var id = seq;
      var timer = null;
      if (hasTimer) {
        timer = setTimeout(function () {
          if (!pending.has(String(id))) return;
          pending.delete(String(id));
          reject(new Error("调用 " + name + " 超时"));
        }, TIMEOUT_MS);
      }
      pending.set(String(id), { resolve: resolve, reject: reject, timer: timer });
      channel.send(JSON.stringify({ id: id, name: name, args: args || {} }));
    });
  }

  var THEME_VARS = {
    background: "--bg",
    surface: "--surface",
    text: "--text",
    muted: "--muted",
    line: "--line",
    primary: "--primary",
    primarySoft: "--primary-soft",
    ok: "--ok",
    okSoft: "--ok-soft",
    bad: "--bad",
    badSoft: "--bad-soft"
  };

  function applyTheme(theme) {
    if (!theme || typeof theme !== "object") return;
    var doc = globalThis.document;
    if (!doc || !doc.documentElement || !doc.documentElement.style) return;
    Object.keys(THEME_VARS).forEach(function (key) {
      var value = theme[key];
      if (typeof value === "string" && value) {
        doc.documentElement.style.setProperty(THEME_VARS[key], value);
      }
    });
  }

  globalThis.installBridge = installBridge;
  globalThis.call = call;
  globalThis.applyTheme = applyTheme;
})();
