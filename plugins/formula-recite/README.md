# 公式默写（formula-recite）

TBank 的公式默写示例插件：在画布上手写数学/物理公式，交给 AI 识别并判分；AI 不可用时可以自己对照标准答案判定。

## 功能

- 手写画布：笔、橡皮、笔粗调节、撤销、清空、方格纸背景；
- 画布可横向/纵向滚动，支持写到视口外；
- 横屏自动切换为左侧题目/判分、右侧手写板；
- 判分结果与解析分成独立卡片，解析保持白底；
- 提交时自动裁掉白边，压成 PNG 再发给 AI；
- AI 识别手写内容，判断与标准答案是否数学等价，给 0–10 分；
- AI 判分后可以手动改判为「作答对 / 作答错」；
- AI 不可用时进入自评模式，仍可正常提交；
- 可选「AI 解析」：按本题、标准答案和手写识别结果生成讲解，支持 Markdown 和 KaTeX/LaTeX 显示；
- 计时：关闭 / 每题倒计时 / 正计时；
- 倒计时结束可自动提交、直接判错或只提醒；
- 配置页可改计时、笔粗、方格纸、自动裁边和自动解析。

## 安装

### 导入 zip

1. 打开 App →「我的」→「设置」→「插件管理」；
2. 导入本目录下的 `formula-recite-1.1.5.zip`；
3. 安装完成后，题库根节点写 `"plugin": "formula-recite"` 即可使用。

zip 内 `manifest.json` 必须在根目录；本目录里的 zip 已经按这个结构打好。

### 从源码安装

开发时可以直接把 `formula-recite/` 目录压缩成 zip，确保 `manifest.json` 在压缩包根目录，再通过插件管理导入。不要直接把整个仓库打成 zip。

## 题库格式

题库根节点：

```json
{
  "plugin": "formula-recite",
  "pluginVersion": 1,
  "questions": []
}
```

题目使用插件声明的 `formula_recite` 类型：

```json
{
  "id": "q_0001",
  "type": "formula_recite",
  "question": "牛顿第二定律",
  "image": "",
  "options": [],
  "correctAnswer": ["F = ma", "ΣF = ma"],
  "analysis": "合外力等于质量乘加速度；注意 F 是合外力。",
  "stats": { "attemptCount": 0, "wrongCount": 0 },
  "pluginData": {
    "subject": "physics",
    "chapter": "动力学",
    "latex": "\\sum \\vec{F} = m\\vec{a}",
    "hint": "合外力、质量、加速度"
  }
}
```

字段说明：

| 字段 | 必填 | 说明 |
| --- | --- | --- |
| `question` | ✅ | 公式名称或提示语，显示在画布上方 |
| `options` | ✅ | 固定为空数组 |
| `correctAnswer` | ✅ | 纯文本等价写法，可以给多个；任一算对 |
| `analysis` | | 结果卡片里的文字解析 |
| `pluginData.subject` | ✅ | `math` 或 `physics` |
| `pluginData.chapter` | | 章节名 |
| `pluginData.latex` | | 标准答案的 LaTeX；用于更漂亮的公式展示 |
| `pluginData.hint` | | 一句话提示，点「提示」显示 |

`pluginData` 的 JSON Schema 以 `manifest.json` 里的 `typeSchemas.formula_recite` 为准。

## 使用流程

1. 进入练习，看到题目和空白画布；
2. 用触控笔/手指/鼠标写公式；画布比视口大，拖动下方/右侧滚动条可以写到更多区域；
3. 点「提交默写」；
4. 配了 DeepSeek Key 时：
   - AI 识别手写内容并给出分数；
   - 页面显示 AI 识别结果、分数和标准答案；
   - 可以点「记作答对 / 记作答错」覆盖 AI 建议；
5. 没配 Key 或 AI 失败时：
   - 显示标准答案，自己判定对错；
   - 可以点「重试 AI」再试一次；
6. 提交后点「下一题」。

计时开启时，倒计时结束会按配置执行「自动提交 / 直接判错 / 只提醒」。

## 配置

设置 → 插件管理 → 公式默写右侧齿轮：

| 配置项 | 默认值 | 说明 |
| --- | --- | --- |
| `timerMode` | `off` | `off` / `countdown` / `stopwatch` |
| `timeLimit` | `60` | 倒计时秒数：30 / 45 / 60 / 90 / 120 |
| `timeoutAction` | `autoSubmit` | `autoSubmit` / `markWrong` / `notify` |
| `penWidth` | `3` | 默认笔粗 1–8 |
| `showGrid` | `true` | 方格纸背景 |
| `autoCrop` | `true` | 提交时裁掉画布白边 |
| `aiExplainAuto` | `false` | 判分后自动请求 AI 解析（多消耗一次 AI 调用） |

配置保存在插件目录的 `config.json`，升级插件时保留。

## AI 说明

- 判分和解析都走插件的 `tbankAiComplete`，Prompt 由插件生成，App 只负责鉴权和发送；
- 判分时会把画布导出的 PNG 作为附图发给 DeepSeek；
- AI 返回的 JSON 包含 `recognized`、`equivalent`、`score`、`reason`；
- 推荐规则：`equivalent === true` 且 `score >= 6` 时建议判对，最终仍由用户确认；
- 未配置 DeepSeek Key、请求失败或模型返回格式异常时，自动退到自评，不会卡住答题；
- AI 判分有模型波动，同一份手写内容可能得到不同分数；重要考试请以标准答案为准。

## 文件结构

```text
formula-recite/
├── manifest.json       # 插件声明、题型、schema、示例
├── index.html          # 练习页入口
├── app.js              # 画布、计时、判分、解析、提交
├── bridge.js           # Android/Windows 宿主桥
├── canvas.js           # 手写画布与导出
├── tex.js              # KaTeX 优先、轻量排版兜底
├── katex/              # 离线 KaTeX 样式、脚本和字体
├── style.css           # 插件样式
├── config.html         # 配置页
├── config.js           # 配置读写与默认值
├── README.md
└── formula-recite-1.1.5.zip
```

## 隐私

- 未开启 AI 或未提交时，手写内容只留在本机；
- 开启 AI 判分/解析后，导出的手写图片和题目文本会发送到 App 配置的 DeepSeek 接口；
- 插件用 `localStorage` 记录每日练习用时，不包含手写图片。

## 版本

- 插件版本：`1.1.5`
- 插件 API：`1`
- 题库类型：`formula_recite`
