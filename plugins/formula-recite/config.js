// 配置页逻辑：默认值、非法值回落、表单读写。
(function () {
  "use strict";

  var DEFAULT_CONFIG = {
    timerMode: "off",
    timeLimit: 60,
    timeoutAction: "autoSubmit",
    penWidth: 3,
    showGrid: true,
    autoCrop: true,
    aiExplainAuto: false
  };

  var TIMER_MODES = ["off", "countdown", "stopwatch"];
  var TIMEOUT_ACTIONS = ["autoSubmit", "markWrong", "notify"];
  var TIME_LIMITS = [30, 45, 60, 90, 120];

  function pickEnum(value, list, fallback) {
    return list.indexOf(value) >= 0 ? value : fallback;
  }

  function pickBool(value, fallback) {
    return typeof value === "boolean" ? value : fallback;
  }

  function pickPenWidth(value) {
    var number = Number(value);
    if (!isFinite(number) || number < 1 || number > 8) return DEFAULT_CONFIG.penWidth;
    return Math.round(number);
  }

  function pickTimeLimit(value) {
    var number = Number(value);
    return TIME_LIMITS.indexOf(number) >= 0 ? number : DEFAULT_CONFIG.timeLimit;
  }

  function mergeConfig(raw) {
    var source = raw && typeof raw === "object" ? raw : {};
    return {
      timerMode: pickEnum(source.timerMode, TIMER_MODES, DEFAULT_CONFIG.timerMode),
      timeLimit: pickTimeLimit(source.timeLimit),
      timeoutAction: pickEnum(source.timeoutAction, TIMEOUT_ACTIONS, DEFAULT_CONFIG.timeoutAction),
      penWidth: pickPenWidth(source.penWidth),
      showGrid: pickBool(source.showGrid, DEFAULT_CONFIG.showGrid),
      autoCrop: pickBool(source.autoCrop, DEFAULT_CONFIG.autoCrop),
      aiExplainAuto: pickBool(source.aiExplainAuto, DEFAULT_CONFIG.aiExplainAuto)
    };
  }

  function byId(id) {
    return document.getElementById(id);
  }

  function fillForm(config) {
    var merged = mergeConfig(config);
    if (byId("timerMode")) byId("timerMode").value = merged.timerMode;
    if (byId("timeLimit")) byId("timeLimit").value = String(merged.timeLimit);
    if (byId("timeoutAction")) byId("timeoutAction").value = merged.timeoutAction;
    if (byId("penWidth")) byId("penWidth").value = String(merged.penWidth);
    if (byId("showGrid")) byId("showGrid").checked = merged.showGrid;
    if (byId("autoCrop")) byId("autoCrop").checked = merged.autoCrop;
    if (byId("aiExplainAuto")) byId("aiExplainAuto").checked = merged.aiExplainAuto;
  }

  function readForm() {
    return mergeConfig({
      timerMode: byId("timerMode") ? byId("timerMode").value : undefined,
      timeLimit: byId("timeLimit") ? Number(byId("timeLimit").value) : undefined,
      timeoutAction: byId("timeoutAction") ? byId("timeoutAction").value : undefined,
      penWidth: byId("penWidth") ? Number(byId("penWidth").value) : undefined,
      showGrid: byId("showGrid") ? byId("showGrid").checked : undefined,
      autoCrop: byId("autoCrop") ? byId("autoCrop").checked : undefined,
      aiExplainAuto: byId("aiExplainAuto") ? byId("aiExplainAuto").checked : undefined
    });
  }

  function save() {
    var config = readForm();
    call("tbankConfigSet", { config: config }).then(
      function () {
        call("tbankToast", { message: "已保存" });
      },
      function (error) {
        call("tbankToast", {
          message: "保存失败：" + (error && error.message ? error.message : error)
        });
      }
    );
  }

  function initPage() {
    if (!byId("save")) return; // 练习页也会加载本文件，只取纯函数，不初始化配置表单
    installBridge(globalThis);
    globalThis.__tbankConfigReceive = function (payload) {
      fillForm(payload && payload.config);
      var versionNode = byId("plugin-version");
      if (versionNode && payload && payload.plugin) {
        versionNode.textContent = (payload.plugin.name || "插件") + " " + (payload.plugin.version || "");
      }
    };
    if (byId("save")) byId("save").addEventListener("click", save);
    if (byId("reset")) {
      byId("reset").addEventListener("click", function () {
        fillForm(DEFAULT_CONFIG);
      });
    }
    call("tbankConfigGet", {}).then(
      function (config) {
        fillForm(config);
      },
      function () {
        fillForm(DEFAULT_CONFIG);
      }
    );
  }

  globalThis.DEFAULT_CONFIG = DEFAULT_CONFIG;
  globalThis.mergeConfig = mergeConfig;

  if (typeof document !== "undefined") {
    if (document.readyState === "loading") {
      document.addEventListener("DOMContentLoaded", initPage);
    } else {
      initPage();
    }
  }
})();
