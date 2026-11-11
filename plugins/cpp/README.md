# C/C++ 代码题（tbank 插件）

给 [tbank](https://github.com/cztrtr/tbank) 用的题型插件。面向大一《C/C++ 程序设计》课程，提供三种题型：

| 题型 id | 名称 | 手机端 | 平板 / PC |
| --- | --- | --- | --- |
| `cpp_read` | 代码阅读 | 只读代码 + 选择 / 简答 | 同左 |
| `cpp_fill` | 代码填空 | 只读代码 + 行内填空 | 同左 |
| `cpp_ide` | 上机编程 | 纯文本作答 | 带行号编辑器 + 自动缩进 |

判分全部在本地完成（选择、填空），编程题交给 DeepSeek 按大一入门课标准评分；没有配 Key 时退回「看参考答案自判」。

## 安装

1. 把本目录打成 zip（`manifest.json` 在 zip 根目录）
2. tbank → 设置 → 插件管理 → 导入本地 zip
3. 新建题库时选择题型「C/C++ 编程题」，或按下方格式手写题库

## 题库格式

```json
{
  "plugin": "cpp",
  "pluginVersion": 1,
  "questions": [
    {
      "id": "Q001",
      "type": "cpp_fill",
      "question": "补全下面的累加程序。",
      "options": [],
      "correctAnswer": ["i++", "+="],
      "analysis": "for 循环缺步长，累加用 +=。",
      "stats": { "attemptCount": 0, "wrongCount": 0 },
      "pluginData": {
        "language": "cpp",
        "code": "#include <iostream>\nusing namespace std;\nint main(){\n    int n, sum = 0;\n    cin >> n;\n    for (int i = 1; i <= n; ____) {\n        sum ____ i;\n    }\n    cout << sum << endl;\n}"
      }
    }
  ]
}
```

### 公共字段

- `type`：`cpp_read` / `cpp_fill` / `cpp_ide`
- `question`：题干
- `correctAnswer`：按题型不同（见下）
- `analysis`：解析，作答后展示
- `stats`、`image`、`options`：由 App 管理

### pluginData

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `language` | `"c"` / `"cpp"` | 必填，决定语法高亮关键字 |
| `code` | string | 阅读 / 填空题的完整代码 |
| `starterCode` | string | 编程题的起始模板 |
| `tests` | string[] | 编程题的测试点描述，最多 8 条 |
| `hint` | string | 一句话提示 |

### 各题型答案约定

**cpp_read**

- 选择题：`options` 放 `{key,text}`，`correctAnswer` 放正确 key，如 `["B"]`
- 简答题：`options` 为空，`correctAnswer` 放参考答案文本，AI 判分

**cpp_fill**

- 代码里用连续四个下划线 `____` 标记空位
- `correctAnswer` 按空位出现顺序排列，如 `["i++", "+="]`
- 比较时忽略空格和换行

**cpp_ide**

- `correctAnswer` 放一份可编译的参考实现
- `pluginData.tests` 放测试点，AI 判分时会参考

## 判分

- 选择 / 填空：本地比对，立即出结果
- 编程 / 简答：调 `tbankAiComplete`，自定义 Prompt 让模型按入门课标准打 0~10 分
  - 语法错误最多 4 分
  - 逻辑正确 7~9 分，完全正确 9~10 分
  - 边界、输出格式问题各扣 1~2 分
  - 只有伪代码最多 6 分
- 达到「判对分数线」（默认 6）记为答对
- AI 失败 / 未配 Key：显示参考答案，用户自己点「答对了 / 答错了」

## 配置

设置 → 插件管理 → 齿轮：

- 作答界面：自动 / 始终手机 / 始终编辑器
- 判对分数线：0~10
- 代码字号：11~20

## 开发

```text
manifest.json   插件声明与题型 schema
index.html      练习页
app.js          桥接 + 渲染 + 判分流程
core.js         纯函数（高亮、空位切分、Prompt、分数解析）
config.html     配置页
config.js       配置页逻辑
style.css       样式（跟随 App 主题）
```

`core.js` 是 UMD 写法，可以直接在 Node 里 `require` 做单元测试：

```bash
node test/core.test.js
```
