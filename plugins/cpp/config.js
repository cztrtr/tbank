(function () {
  'use strict';

  var pendingCalls = {};
  var callSeq = 0;
  var current = {};

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

  function num(value, fallback, min, max) {
    var n = Number(value);
    if (isNaN(n)) return fallback;
    if (n < min) return min;
    if (n > max) return max;
    return Math.round(n);
  }

  function fillForm(config) {
    config = config || {};
    var mode = config.mode === 'mobile' || config.mode === 'ide'
      ? config.mode
      : 'auto';
    var threshold = num(config.threshold, 6, 0, 10);
    var fontSize = num(config.fontSize, 13, 11, 20);

    document.getElementById('mode').value = mode;
    document.getElementById('threshold').value = String(threshold);
    document.getElementById('threshold-value').textContent = String(threshold);
    document.getElementById('fontSize').value = String(fontSize);
    document.getElementById('fontSize-value').textContent = String(fontSize);

    current = { mode: mode, threshold: threshold, fontSize: fontSize };
  }

  function setStatus(text) {
    document.getElementById('status').textContent = text;
  }

  function save() {
    var config = {
      mode: document.getElementById('mode').value,
      threshold: num(document.getElementById('threshold').value, 6, 0, 10),
      fontSize: num(document.getElementById('fontSize').value, 13, 11, 20)
    };

    hostCall('tbankConfigSet', { config: config }).then(function () {
      current = config;
      setStatus('已保存');
      toast('配置已保存');
      setTimeout(function () { setStatus(''); }, 1800);
    }).catch(function (error) {
      setStatus('保存失败：' +
        (error && error.message ? error.message : error));
    });
  }

  function bind() {
    var threshold = document.getElementById('threshold');
    var fontSize = document.getElementById('fontSize');

    threshold.addEventListener('input', function () {
      document.getElementById('threshold-value').textContent = threshold.value;
    });
    fontSize.addEventListener('input', function () {
      document.getElementById('fontSize-value').textContent = fontSize.value;
    });
    document.getElementById('save').addEventListener('click', save);
  }

  window.__tbankConfigReceive = function (payload) {
    if (payload && payload.plugin) {
      document.title = '配置 · ' + (payload.plugin.name || 'C/C++ 代码题');
    }
    fillForm(payload && payload.config);
  };

  function boot() {
    bind();
    hostCall('tbankConfigGet', {}).then(function (config) {
      fillForm(config);
    }).catch(function () {
      fillForm({});
    });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot);
  } else {
    boot();
  }
})();
