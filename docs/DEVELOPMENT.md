# TBank

一个使用 Flutter 编写的本地题库练习 App。

题库是普通的 `.json` 文件，可以放在手机存储的任意目录；App 负责扫描目录、读取题目、记录每题累计作答/答错次数，并把统计回写到原文件。

> 当前状态：题库管理、练习（含题目配图）、本地统计、首页打卡卡片与语录卡、ME 页设置入口已实现；设置页目前只有 DeepSeek 密钥一项。

## 功能

- 底部导航：`Home` / `题库管理` / `练习` / `ME`
- 首页
  - 每次启动从 `assets/images/home_bg/` 随机选择一张背景图，使用 `BoxFit.cover` 等比铺满
  - 顶部居中的圆角正方形打卡卡片（半透明毛玻璃）：显示「打卡」、累计天数、日期
  - 点击卡片后文案变为 `HELLO`、天数隐藏、日期放大，1 秒后卡片淡出离场；同时按连续打卡规则更新 `clockOnNum` 和 `lastClockOnDate`
  - 如果今天已经打过卡，卡片显示「已打卡」、保留天数，但不可再次点击；**只在本次启动展示 3 秒，随后自动淡出并从布局中移除**（语录卡随之上移）
  - 打卡卡片下方是一张半透明圆角「语录卡」：启动时从 `assets/texts/quotes.txt` 随机取一句；点击换下一句，且不会连续两次显示同一句
  - 语录文件的格式：一行一句，空行忽略，`#` 开头的行是注释
- 题库管理
  - 右上角 `+` 调起系统目录选择器
  - 扫描所选目录下的 `.json` 文件
  - 点击文件进入练习
  - 每项右侧的删除按钮只移除 `config.json` 里的目录记录，不会删除目录或题目文件
- 练习
  - 单选 `single_choice`
  - 多选 `multiple_choice`
  - 判断 `true_false`
  - 填空/解释 `fill_blank`（配置了 DeepSeek 密钥时由 AI 判 0-10 分，低于 6 分判错；未配置时退回「展示答案 + 自判」）
  - 选择题答完后左侧「AI 解析」、右侧「下一题」；AI 解析结果显示在页面最下方的独立框里
  - 题目上方显示该题累计「已作答 / 答错」次数
  - 题目配图：JSON 的 `image` 非空时，从**题库 JSON 所在目录**加载同名图片；选择题显示在选项下方，填空/解释题紧跟题干。文件缺失或无法解码时显示占位框并标出文件名
- 统计与持久化
  - 每题判分后更新内存统计，并写一次文档目录下的工作副本
  - 整份做完、App 进入后台、页面销毁时，把工作副本回拷到题库所在文件夹
- 配置
  - `config.json` 保存题库目录列表、连续打卡天数、上次打卡日期和 DeepSeek API Key（base64）
  - 配置和目录变化通过 `ValueNotifier` 全局广播

## 数据流

```text
题库文件夹里的 xxx.json
        │  QuestionBankStorage.load()
        │  1. 复制到 getApplicationDocumentsDirectory()
        ▼
App 文档目录下的 xxx.json（工作副本）
        │  2. 解析
        ▼
内存中的 QuestionBank
        │  3. 每题判分后 QuestionStats 递增
        ▼
工作副本写回（QuestionBankStorage.save）
        │  4. 完成 / 进后台 / 页面销毁 / 换题库
        ▼
回拷到题库文件夹里的原 xxx.json（syncBack）
```

这样设计的原因：题目只有约 100 道，整份 JSON 很小，不需要数据库或增量写；所有答题过程中的写入都发生在 App 私有目录，只有最后同步时才碰用户目录，失败也不会影响继续练习。

## 目录结构

```text
lib/
├── main.dart                       # 入口、主题、启动时加载配置
├── models/
│   ├── question_bank.dart          # 题库/题目/选项/统计/题型枚举
│   └── question_bank_file.dart     # 题库文件（名称 + 引用 + 所属目录）
├── services/
│   ├── app_config.dart             # config.json 读写、全局 notifier
│   ├── question_bank_storage.dart  # 读取/保存/回拷题库文件
│   ├── bank_io.dart                # 存储访问统一入口（SAF / 文件路径）
│   ├── saf.dart                    # Android SAF 通道封装
│   └── ds_api_service.dart         # DeepSeek API 调用
├── screen/
│   ├── main_screen.dart            # 底部导航 + IndexedStack
│   ├── home_page.dart              # 随机背景 + 打卡卡片
│   ├── question_bank_page.dart     # 目录选择、扫描、题库列表
│   ├── practice_page.dart          # 练习界面与答题逻辑
│   ├── me_page.dart                # 个人中心，提供设置入口
│   └── settings_page.dart          # 设置页
└── widgets/
    ├── quote_card.dart             # 首页语录卡：随机一句、点击换句
    └── question_image.dart         # 题目配图：加载 + 缺失/损坏占位
```

## 快速开始

环境要求：

- Flutter 3.47+ / Dart 3.13+
- Android SDK 36（`compileSdk` 使用 Flutter 默认值）
- JDK 17+

```bash
cd tbank
flutter pub get
flutter run
```

打包 APK：

```bash
flutter build apk --release
```

输出：

```text
build/app/outputs/flutter-apk/app-release.apk
```

目前 release 仍使用 debug 签名（`android/app/build.gradle.kts` 中配置），可以直接安装测试，但不能上传 Google Play；正式发布需要生成 keystore 并配置 `signingConfigs`。

## 配置文件

位置：`getApplicationSupportDirectory()/config.json`

首次启动时由 `AppConfig.init()` 创建，默认内容：

```json
{
  "questionBankDirs": [],
  "clockOnNum": 0,
  "lastClockOnDate": "",
  "dsApiKey": null
}
```

字段说明：

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `questionBankDirs` | string[] | 题库目录引用列表：Android 为 SAF 的 `content://` URI，桌面为绝对路径 |
| `clockOnNum` | int | 连续打卡天数，默认为 `0`；昨天打过则 +1，断签或首次打卡重置为 1 |
| `lastClockOnDate` | string | 上次打卡日期，格式 `yyyy-MM-dd`，空字符串表示从未打卡 |
| `dsApiKey` | string \| null | DeepSeek API Key，**base64 编码后**存储；`null` 表示未配置 |

已有旧配置没有 `lastClockOnDate` 时，会按空字符串处理，下一次打卡会从 1 重新开始。

注意：base64 只是编码不是加密，拿到 `config.json` 就能解回明文。

## 题库 JSON 格式

```json
{
  "questions": [
    {
      "id": "Q001",
      "type": "single_choice",
      "question": "中国的首都是哪座城市？",
      "image": "",
      "options": [
        { "key": "A", "text": "上海" },
        { "key": "B", "text": "北京" },
        { "key": "C", "text": "广州" },
        { "key": "D", "text": "深圳" }
      ],
      "correctAnswer": ["B"],
      "analysis": "北京是中华人民共和国的首都；上海、广州、深圳都是重要的中心城市，但不是首都。",
      "stats": {
        "attemptCount": 120,
        "wrongCount": 15
      }
    },
    {
      "id": "Q002",
      "type": "multiple_choice",
      "question": "以下哪些属于编程语言？（多选）",
      "image": "",
      "options": [
        { "key": "A", "text": "Python" },
        { "key": "B", "text": "HTML" },
        { "key": "C", "text": "Java" },
        { "key": "D", "text": "Photoshop" }
      ],
      "correctAnswer": ["A", "C"],
      "stats": { "attemptCount": 85, "wrongCount": 32 }
    },
    {
      "id": "Q003",
      "type": "true_false",
      "question": "地球是太阳系中最大的行星。",
      "image": "",
      "options": [
        { "key": "A", "text": "正确" },
        { "key": "B", "text": "错误" }
      ],
      "correctAnswer": ["B"],
      "analysis": "太阳系中体积最大的行星是木星，地球只排第五。",
      "stats": { "attemptCount": 200, "wrongCount": 45 }
    },
    {
      "id": "Q004",
      "type": "single_choice",
      "question": "图中白色圈内的结构是？",
      "image": "q004.jpg",
      "options": [
        { "key": "A", "text": "紧密连接" },
        { "key": "B", "text": "桥粒" }
      ],
      "correctAnswer": ["B"],
      "stats": { "attemptCount": 12, "wrongCount": 3 }
    },
    {
      "id": "Q005",
      "type": "fill_blank",
      "question": "水的化学式是______。",
      "image": "",
      "options": [],
      "correctAnswer": ["H2O"],
      "stats": { "attemptCount": 60, "wrongCount": 8 }
    }
  ]
}
```

规则：

- 根节点必须是对象，题目都在 `questions` 数组里；
- `type` 只认这四个值：`single_choice`、`multiple_choice`、`true_false`、`fill_blank`；
- `correctAnswer` 一律是数组：单选单元素 `["B"]`、多选多元素 `["A","C"]`、填空 `["H2O"]`；
- `correctAnswer` 里的每个值都必须能在 `options[].key` 里找到对应项（填空题 `options` 为空，不受限）；
- `analysis` 是纯文本解析，作答后显示在判分结果下方，答对答错都展示；为空则不显示解析框；
- 填空和解释都用 `fill_blank`，`options` 为空数组；
- `stats` 可以缺省，解析时会补 `0 / 0`；
- 未知 `type` 会按 `fill_blank` 处理，避免一条脏数据导致整份题库打不开；
- `image` 是**文件名**，不是路径；非空时图片必须和这道题所在的 JSON 放在同一个目录，一道题最多一张图；留空或省略表示无图；
- `id` 建议唯一，重复不会报错但不利于排查；
- 写回时会重新序列化整个文件，顶层除 `questions` 外的字段不会保留。

## 核心类与常用方法

### AppConfig（`lib/services/app_config.dart`）

| 成员 | 说明 |
| --- | --- |
| `AppConfig.init()` | 启动时调用，读取或创建 `config.json`，加载到内存 |
| `AppConfig.clockOnNotifier` | 打卡天数的 `ValueNotifier<int>`，首页监听它刷新 |
| `AppConfig.hasCheckedInToday` | 今天是否已经打过卡 |
| `AppConfig.checkInToday()` | 完成今天打卡：今天已打返回 false；昨天打过则 +1；断签重置为 1 |
| `AppConfig.questionBankDirs` | 题库目录的只读快照 |
| `AppConfig.questionBankDirsNotifier` | 题库目录的 `ValueNotifier<List<String>>`，界面监听它自动刷新 |
| `AppConfig.addQuestionBankDir(String)` | 追加目录（去重）并落盘 |
| `AppConfig.removeQuestionBankDir(String)` | 删除目录并落盘 |
| `AppConfig.dsApiKey` | 当前 DeepSeek API Key（内存中明文） |
| `AppConfig.dsApiKeyNotifier` | API Key 的 `ValueNotifier<String?>` |
| `AppConfig.setDsApiKey(String?)` | 设置或清除 Key，base64 编码后写入 `config.json` |

### QuestionBankStorage（`lib/services/question_bank_storage.dart`）

| 成员 | 说明 |
| --- | --- |
| `QuestionBankStorage(file:)` | 绑定一个题库文件（`QuestionBankFile`） |
| `load()` | 复制源文件到文档目录，读取并解析成 `QuestionBank` |
| `save(QuestionBank)` | 把整份题库写回工作副本，内部串行队列 |
| `syncBack()` | 把工作副本回拷到源文件，返回是否成功 |

### Saf（`lib/services/saf.dart`）

Android Storage Access Framework 的 Dart 封装，对应原生 `tbank/saf` 通道
（实现见 `android/app/src/main/kotlin/com/example/tbank/MainActivity.kt`）。
所有 IO 在原生线程池执行后切回主线程，不阻塞 UI。

| 成员 | 说明 |
| --- | --- |
| `Saf.isSupported` | 是否 Android；桌面端为 false，走文件路径 |
| `Saf.pickDirectory()` | 弹系统目录选择器，返回可跨重启的 tree URI；取消返回 null |
| `Saf.listChildren(uri, extension:)` | 列出目录下的一级文件 |
| `Saf.readText(uri)` / `Saf.writeText(uri, text)` | 读写 UTF-8 文本，写入用 `wt` 模式会截断旧内容 |
| `Saf.readChildBytes(dirUri, name)` | 按文件名读子文件字节，题目配图用 |
| `Saf.releasePermission(uri)` | 释放目录授权 |

### BankIo（`lib/services/bank_io.dart`）

存储访问的统一入口，把「SAF URI」和「桌面文件路径」收敛成同一套 API。
判断依据只有一条：引用是否以 `content://` 开头。

| 成员 | 说明 |
| --- | --- |
| `listJsonFiles(dirRef)` | 列出目录下的 `.json`，两种存储都支持 |
| `readText(fileRef)` / `writeText(fileRef, text)` | 读写题库 JSON，读取时自动去掉 BOM |
| `readSiblingBytes(dirRef, name)` | 读同级文件字节（题目配图） |
| `releaseDirectory(dirRef)` | 释放 SAF 授权；桌面端空操作 |
| `displayNameOf(dirRef)` | 从引用推导展示名，例如 `content://…/tree/primary%3ABooks` → `Books` |

### DsApiService（`lib/services/ds_api_service.dart`）

DeepSeek 对话接口（OpenAI 兼容协议）的封装，模型固定为 `deepseek-flash`。
API Key 从 `AppConfig.dsApiKey` 读取，未配置时抛 `DsApiException`。

| 成员 | 说明 |
| --- | --- |
| `ask(content, stream:, thinking:)` | 通用问答；`thinking` 控制是否启用思考模式 |
| `scoreAnswer(question:, standardAnswer:, userAnswer:, imageBytes:)` | 给主观题打 0-10 分，供填空/解释题判分 |
| `explainQuestion(question:, options:, correctAnswer:, imageBytes:)` | 生成选择题解析，供「AI 解析」按钮使用 |
| `sseDelta(line)` | 解析一行 SSE，区分正文 `content` 与思考过程 `reasoning_content` |

说明：

- 传了 `imageBytes` 时按「文本 + `image_url` 内容块」发送（`_withOptionalImage`），MIME 按文件头判断
- 所有错误统一转成 `DsApiException`，带中文提示和 HTTP 状态码
- 没有引入 `dart:io`，因此也可在 Web 端编译

### 页面

| 类 | 说明 |
| --- | --- |
| `MainScreen` | 底部导航 + `IndexedStack`，保存当前选中的题库 |
| `MainScreen._openBank(QuestionBankFile)` | 点击题库后的回调：保存选中项并切到练习 tab |
| `QuestionBankPage(onOpenBank:)` | 扫描目录，点击文件时把 `QuestionBankFile` 交给父级 |
| `PracticePage(bank:)` | 接收题库并完成加载、答题、统计、回拷 |
| `MePage` | 个人中心，提供「设置」入口 |
| `SettingsPage` | 设置页（目前只有 DeepSeek 密钥一项） |

## 页面切换与状态

- 四个页面放在 `IndexedStack` 里，切 tab 不销毁页面，因此扫描结果和练习进度会保留；
- `MainScreen` 持有 `_selectedBank`，每次重建把最新的 `bank` 传给 `PracticePage`；
- `PracticePage` 在 `didUpdateWidget` 里比较 `oldWidget.bank?.uri` 和 `widget.bank?.uri`，换了文件才重新加载；
- 题库页通过 `onOpenBank` 回调把选择交给父级，自己不直接操作练习页；
- 练习页用 `_loadToken` 防止旧的异步加载覆盖新加载。

## 继续开发指南

### 1. 完成 ME 页

Home 已经是完整实现（`home_page.dart`：随机背景 + 打卡卡片 + 语录卡）。
ME 目前只有「设置」一个入口（`me_page.dart` 里的列表项），其余条目可以继续往下追加，
例如关于、导入导出等：

```dart
ValueListenableBuilder<List<String>>(
  valueListenable: AppConfig.questionBankDirsNotifier,
  builder: (context, dirs, _) => Text('题库目录：${dirs.length} 个'),
)
```

### 2. 新增配置项

1. 在 `AppConfig` 添加字段和 getter；
2. 在 `_load()` 解析；
3. 在 `_save()` 序列化；
4. 如果是需要驱动界面的字段，参照 `questionBankDirsNotifier` 加一个 `ValueNotifier`；
5. 默认值要考虑旧配置文件缺失字段的情况。

### 3. 新增题型

1. 在 `QuestionType` 增加枚举和 `value`；
2. 在 `QuestionType.parse` 中能识别；
3. `Question.toJson` 里 `correctAnswer` 始终写成数组；
4. `PracticePage._buildQuestion` 增加对应 UI；
5. 判分逻辑放在 `_submitChoice` 或新增方法里，最后统一走 `_recordAnswer`。

### 4. 修改判分 / 统计

- 选择题判分在 `PracticePage._submitChoice`，目前是“集合完全相等”；
- 统计更新在 `_recordAnswer`，统一处理 `attemptCount` / `wrongCount`；
- 保存时机在 `_recordAnswer` 末尾的 `_persist`；
- 回拷时机在 `_next` 的完成分支、`didChangeAppLifecycleState`、`dispose`、换题库前的 `_loadBank`。

### 5. 读取题库数据

```dart
// 监听目录变化
ValueListenableBuilder<List<String>>(
  valueListenable: AppConfig.questionBankDirsNotifier,
  builder: (context, dirs, _) => ...,
)

// 一次性读取当前目录
final dirs = AppConfig.questionBankDirsNotifier.value;

// 页面内加载某个题库
final storage = QuestionBankStorage(file: file);
final bank = await storage.load();
```

### 6. 建议补充的功能

- 错题本：按 `wrongCount / attemptCount` 过滤或新建一个错题题库文件；
- 收藏/标记：需要扩展 JSON 字段，并同步修改 `Question.fromJson/toJson`；
- 题库导入/导出：仍可通过系统选择器选文件，复制到题库目录；
- 学习记录：在 `QuestionStats` 外新增时间戳或历史数组。

### 7. 改首页语录

编辑 `assets/texts/quotes.txt`：一行一句，空行和 `#` 开头的行会被忽略；文件必须存成 UTF-8。

改完需要**完全重启** App（重新 `flutter run`），热重载读不到新资源——文案是通过 `pubspec.yaml` 的 `assets` 打进包里的。

想换文件或同时存在多份语录，可以显式传参：

```dart
const QuoteCard(assetPath: 'assets/texts/other.txt'),
```

记得在 `pubspec.yaml` 的 `assets` 里加上对应目录。

### 8. 给题目加配图

1. 把图片放进该题所在 JSON 的**同一个目录**；
2. 在这道题的 JSON 里写文件名：`"image": "q004.jpg"`；
3. 一道题只支持一张图；没有图就写 `""` 或省略该字段。

路径由 `QuestionBankStorage.sourceDirectoryRef`（题库所在目录的引用）解析，
而不是文档目录里的工作副本 —— 因为 `load()` 只复制 JSON，图片不会跟着复制。

## Android 存储与平台差异

### 存储访问：SAF（不申请任何存储权限）

`android/app/src/main/AndroidManifest.xml` 里只有一条权限：

```xml
<uses-permission android:name="android.permission.INTERNET" />
```

`INTERNET` 是 AI 判分 / AI 解析访问 `https://api.deepseek.com` 用的，普通权限、安装时不弹窗。
构建产物里另有 AndroidX 自动合并的 `DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION`（非存储类，无需授权）。

> 注意：Flutter 只在 `src/debug` 和 `src/profile` 的模板 manifest 里自动加 `INTERNET`，
> **release 包必须在主 manifest 显式声明**。漏了的话手机端会报
> `网络请求失败：Failed host lookup: 'api.deepseek.com'`，而桌面端不受影响（Windows 没有这层权限控制）。
> 排查方法：`aapt2 dump permissions app-release.apk` 看有没有 `INTERNET`。

读写流程：

1. 用户点右上角 `+`，原生层弹出 `ACTION_OPEN_DOCUMENT_TREE`；
2. 选中目录后调用 `takePersistableUriPermission`，拿到可跨重启的 tree URI；
3. URI 字符串存进 `config.json` 的 `questionBankDirs`；
4. 之后列举、读取、写回全部通过 `ContentResolver` 完成。

为什么改：`MANAGE_EXTERNAL_STORAGE`（所有文件访问）属于高风险权限，
国产 ROM 的安全引擎普遍把它判定为可疑应用（用户看到「报毒」），
Google Play 也需要人工申报审核。改用 SAF 后：

- 权限层面的风险特征消失；
- 授权范围收窄到用户手动选中的那个文件夹；
- 用户可以在「题库管理」里主动撤销。

### 桌面端

Windows / Linux / macOS 仍然用普通文件路径：`BankIo` 检测到引用不以
`content://` 开头就走 `dart:io`，目录选择继续用 `file_picker`。

### 平台限制

- 授权是「按目录」的，不能跨目录访问；同一目录下的 `.json` 共用一份授权；
- 用户可能在系统设置里撤销授权，撤销后该目录会显示「读取失败」，
  移除记录再重新添加即可恢复；
- Android 上旧版本存的绝对路径已无法访问，升级后会提示「旧版目录记录已失效」，
  需要删除后重新添加（题库文件本身不受影响）；
- iOS 上 `file_picker` 只能拿到临时路径，长期使用需要接入
  `UIDocumentPicker` + security-scoped bookmark，目前未适配。

## 构建环境注意事项

项目目前使用的环境组合比较新，构建时可能遇到以下问题：

### 1. Gradle 下载慢

`android/settings.gradle.kts` 和 `android/build.gradle.kts` 已加入阿里云 Maven 镜像；`pub` 侧可以用：

```bat
setx PUB_HOSTED_URL "https://pub.flutter-io.cn"
setx FLUTTER_STORAGE_BASE_URL "https://storage.flutter-io.cn"
```

### 2. Gradle 本体下载

如果 `services.gradle.org` 太慢，可以把 `android/gradle/wrapper/gradle-wrapper.properties` 的 `distributionUrl` 换成国内镜像，或把下载好的 zip 放进：

```text
C:\Users\<用户名>\.gradle\wrapper\dists\gradle-9.3.1-all\<hash>\
```

### 3. API 37 与 permission_handler

`permission_handler_android 14.1.0` 曾要求 `compileSdk = 37`，而 SDK 只有 `android-37.0` 这种小版本平台，会出现：

```text
Failed to find target with hash string 'android-37'
```

当前 `pubspec.yaml` 已固定 `permission_handler: 12.0.1`，其 Android 插件使用 compileSdk 35，可避开该问题。

### 4. Kotlin 增量缓存

`android/gradle.properties` 中设置了：

```properties
kotlin.incremental=false
```

用于规避 Windows 下 `Could not close incremental caches` 的缓存损坏问题；如果环境稳定，可以删掉这行恢复增量编译。

### 5. NDK

`android/app/build.gradle.kts` 里写的是 `ndkVersion = flutter.ndkVersion`（默认 28.2.13676358）。

当前依赖（`file_picker` / `path_provider` / `permission_handler`）都是纯 Java/Kotlin 插件，**没有 C/C++ 代码，所以本机不装 NDK 也能正常构建**。

只有当你引入带原生代码的插件（音视频、加解密、某些图像库等）时才会报 `NDK not configured`，那时再：

- 把对应版本放到 `D:\Android\Sdk\ndk\<完整版本号>\`，或
- 把 `ndkVersion = flutter.ndkVersion` 改成实际已安装的版本号。

## 已知限制

- **工作副本以源文件为准**：每次打开题库都会用源文件覆盖副本，若上次没成功回拷，副本里的新统计会丢失；
- **同名文件冲突**：不同目录下的同名 `.json` 会映射到文档目录下同一个副本；
- **强杀进程可能丢最后一次同步**：生命周期回调不保证执行，但工作副本通常是安全的；
- **同一题库练完后再点一次不会自动重开**：`didUpdateWidget` 比较的是路径，路径没变不会重新加载；可以点完成页的“再练一遍”，或给选择加一个序号；
- **填空/解释的判分依赖 DeepSeek**：配置了 Key 时由 AI 打 0-10 分（低于 6 分判错），未配置或请求失败时退回“答对了 / 答错了”自判；AI 判分有模型波动，同一答案分数可能不完全一致；
- **只扫描目录第一层**：需要递归时把 `dir.list(followLinks: false)` 改为 `recursive: true`；
- **删除目录记录会带走该目录下所有题库**：列表按文件展示，但删除操作移除的是整个目录记录，同一目录里的其它 `.json` 也会一起从列表消失（文件本身不删）；
- **界面状态都在页面 State 里**：没有引入 Provider/Riverpod，跨页面共享只通过 AppConfig 的 notifier；
- **配图不会被复制**：`load()` 只复制 JSON 到文档目录，图片始终从题库所在目录读取。因此源目录被删除、改名或权限被收回后，图片会退化成「图片不存在」占位框（不影响答题）；
- **配图高度上限 320px**：超过这个高度的图会被等比缩放到 320 以内，长截图可能看不清；改 `QuestionImage.maxHeight` 即可；
- **assets 体积偏大**：`assets/images/home_bg/` 里有单张 23 MB 的图，全部背景合计约 48 MB，会直接计入安装包。瘦身时优先压缩或裁掉这里。

## 开发约定

- 页面里尽量使用 `Theme.of(context).colorScheme`，不要把颜色写死；
- 异步操作之后使用 `context` 或 `setState` 前先检查 `mounted`；
- 题库文件读写统一走 `QuestionBankStorage`，不要在页面里直接 `File` 操作；
- 配置读写统一走 `AppConfig`，不要绕过它直接改 `config.json`；
- 每道题的统计更新统一走 `_recordAnswer`，避免重复计数；
- 新增需要跨页面共享的状态时，优先复用 `ValueNotifier` 模式，而不是再引入一套状态管理。
