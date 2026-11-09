# 插件开发指南

本文档面向第三方题型插件作者。TBank 的插件是**运行时加载的 HTML/JS 页面**，Android 和 Windows 共用同一套插件代码；App 只提供题库、统计、持久化和通用桥接口。

## 1. 目录结构

```text
plugins/<id>/
  manifest.json      必需
  index.html         练习页入口
  config.html        可选，配置页入口
  config.json        App 保存的配置（自动生成）
  index.js / style.css / ...
```

`<id>` 必须匹配 `^[a-z0-9][a-z0-9_-]{1,31}$`。

## 2. manifest.json

```json
{
  "id": "coding",
  "name": "代码题",
  "version": "1.0.0",
  "apiVersion": 1,
  "description": "编程题与代码审查",
  "types": ["coding", "code_review"],
  "typeNames": {
    "coding": "代码题",
    "code_review": "代码审查"
  },
  "typeDescriptions": {
    "coding": "代码题：options 为空，correctAnswer 放参考代码，解析写关键步骤。",
    "code_review": "代码审查：题干给代码，correctAnswer 写问题与修改建议。"
  },
  "typeSchemas": {
    "coding": {
      "type": "object",
      "required": ["language", "starterCode"],
      "properties": {
        "language": {"type": "string"},
        "starterCode": {"type": "string"},
        "tests": {"type": "array", "items": {"type": "string"}}
      }
    }
  },
  "typeExamples": {
    "coding": {
      "language": "dart",
      "starterCode": "String f() { return ''; }",
      "tests": ["f() == ''"]
    }
  }
}
```

- `types`：写入题目 JSON 的 `type` 标识；
- `typeNames`：出题界面显示名；
- `typeDescriptions`：AI 出题说明；
- `typeSchemas` / `typeExamples`：`pluginData` 的 JSON Schema 和示例；
- 也兼容 `questionSchema` / `questionExample` 作为所有题型的默认值。

## 3. 题库格式

一个题库只能由一个插件处理：

```json
{
  "plugin": "coding",
  "pluginVersion": 1,
  "questions": [
    {
      "id": "Q001",
      "type": "coding",
      "question": "实现函数 f",
      "image": "",
      "options": [],
      "correctAnswer": ["String f() { ... }"],
      "analysis": "考察……",
      "stats": {"attemptCount": 0, "wrongCount": 0},
      "pluginData": {
        "language": "dart",
        "starterCode": "String f() { ... }"
      }
    }
  ]
}
```

公共字段由 App 管理；`pluginData` 是插件私有对象，App 不解释，只原样保存和注入。

## 4. 练习页桥

宿主加载 `index.html` 后调用：

```js
window.__tbankReceive(context)
```

`context` 结构：

```json
{
  "plugin": "coding",
  "index": 0,
  "total": 10,
  "answered": false,
  "wasCorrect": false,
  "selected": [],
  "correctAnswerText": "...",
  "mistakeScore": null,
  "isMistakeDone": false,
  "aiEnabled": true,
  "question": {
    "id": "Q001",
    "type": "coding",
    "question": "...",
    "options": [],
    "correctAnswers": ["..."],
    "analysis": "...",
    "image": "",
    "imageDataUrl": "data:image/png;base64,...",
    "pluginData": {},
    "stats": {"attemptCount": 0, "wrongCount": 0}
  },
  "theme": {
    "background": "#...",
    "surface": "#...",
    "text": "#...",
    "muted": "#...",
    "line": "#...",
    "primary": "#...",
    "primarySoft": "#...",
    "ok": "#...",
    "okSoft": "#...",
    "bad": "#...",
    "badSoft": "#..."
  }
}
```

插件 → 宿主使用统一消息：

```js
{ id, name, args }
```

Android 用 `window.TBankChannel.postMessage(JSON.stringify(msg))`；Windows 用
`window.chrome.webview.postMessage(JSON.stringify(msg))`。宿主回：

```js
window.__tbankResolve(id, result)
window.__tbankReject(id, message)
```

推荐插件里封装成 Promise（standard 的 `app.js` 就是现成例子）。

### 可用接口

| 接口 | 参数 | 返回 |
| --- | --- | --- |
| `tbankSubmit` | `{correct, selected}` | `true`，App 更新统计/错题本 |
| `tbankNext` / `tbankPrevious` | 无 | `true` |
| `tbankAiExplain` | `{answer}` | AI 解析文本 |
| `tbankAiScore` | `{answer, images: [dataUrl]}` | `0-10` 整数 |
| `tbankReadBank` | 无 | 当前题库原始 JSON 文本 |
| `tbankReadImage` | `{name}` | `{dataUrl}` |
| `tbankUpdatePluginData` | `{pluginData: {...}}` | `true`，按 schema 校验后写回当前题 |
| `tbankFetch` | `{url, method?, headers?, body?}` | `{status, body}` / `{error}` |
| `tbankClipboardRead` | 无 | 文本 |
| `tbankClipboardWrite` | `{text}` | `true` |
| `tbankPickImage` | `{source: 'camera' \| 'gallery'}` | `{dataUrl}` / `{cancelled}` / `{error}` |
| `tbankToast` | `{message}` | `true` |

说明：

- `tbankFetch` 只允许 http/https，30 秒超时、1 MB 响应上限；
- `tbankReadBank` 会暴露全部答案和解析，只应安装可信插件；
- 插件自己的持久化可直接使用 WebView `localStorage`；
- `tbankUpdatePluginData` 只修改当前题的私有数据，不能改 `id/type/stats` 等公共字段。

## 5. 配置页

插件根目录放 `config.html` 后，插件管理页右侧的齿轮会打开它。

宿主注入：

```js
window.__tbankConfigReceive({
  plugin: { id, name, version, apiVersion, types },
  config: { /* 当前 config.json */ }
})
```

配置接口：

| 接口 | 参数 | 返回 |
| --- | --- | --- |
| `tbankConfigGet` | 无 | 当前配置对象 |
| `tbankConfigSet` | `{config: {...}}` | `true` |
| `tbankToast` | `{message}` | `true` |

配置保存在 `plugins/<id>/config.json`，升级插件时保留、卸载时删除，最大 256 KB。

## 6. AI 出题约定

出题界面按插件列出题型；App 把用户要求和插件的 `typeDescriptions`、`typeSchemas`、`typeExamples` 一起发给模型。

- 每道题的 `type` 必须是插件声明的 id；
- 有 `typeSchemas` 的题型，`pluginData` 必须存在并通过校验；
- 生成按题型配额进行，每个已选题型至少 1 道；
- 某题型返回不足或校验失败会立即重试，默认每题型最多 4 次；
- 全部题型覆盖后才写入文件；题量小于题型数时直接报错。

写入文件时根节点写 `plugin` / `pluginVersion`。

## 7. schema 支持范围

`PluginSchemaValidator` 支持：

`type`、`required`、`properties`、`additionalProperties`、`items`、`enum`、`const`、`allOf`、`anyOf`、`oneOf`、`minLength`、`maxLength`、`minimum`、`maximum`、`minItems`、`maxItems`、`pattern`。

暂不支持 `$ref`；遇到会明确报错。

## 8. 打包与安装

把插件根目录打成 zip：

```text
manifest.json
index.html
config.html
...
```

设置 → 插件管理 → 导入本地 zip / 从网络下载 zip。zip 内可以根目录直接放
`manifest.json`，也可以套一层 `<id>/`。

## 9. 安全提示

- 只安装可信插件；
- 插件能读取当前题库、调用网络代理和剪贴板；
- 不要硬编码 API Key，AI Key 由宿主保管；
- `pluginData` 不要放超大二进制，建议只存结构化字段。

## 10. 开发检查

```bash
flutter analyze
flutter test
```

标准插件资源位于 `assets/plugins/standard/`，可作为完整参考实现。
