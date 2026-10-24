# TBank

一个使用 Flutter 编写的本地题库刷题 App。

题库是普通的 `.json` 文件，可以放在手机存储的任意目录；App 负责扫描目录、读取题目、记录每题累计作答/答错次数，并把统计回写到原文件。

> 当前状态：题库管理、刷题（含题目配图）、本地统计、首页打卡卡片与语录卡已实现；ME 还是占位页。

## 功能

- 底部导航：`Home` / `题库管理` / `刷题` / `ME`
- 首页
  - 每次启动从 `assets/images/home_bg/` 随机选择一张背景图，使用 `BoxFit.cover` 等比铺满
  - 顶部居中的圆角正方形打卡卡片（半透明毛玻璃）：显示「打卡」、累计天数、日期
  - 点击卡片后文案变为 `HELLO`、天数隐藏、日期放大，1 秒后卡片淡出离场；同时按连续打卡规则更新 `clockOnNum` 和 `lastClockOnDate`
  - 如果今天已经打过卡，卡片显示「已打卡」、保留天数，但不可再次点击
  - 打卡卡片下方是一张半透明圆角「语录卡」：启动时从 `assets/texts/quotes.txt` 随机取一句；点击换下一句，且不会连续两次显示同一句
  - 语录文件的格式：一行一句，空行忽略，`#` 开头的行是注释
- 题库管理
  - 右上角 `+` 调起系统目录选择器
  - 扫描所选目录下的 `.json` 文件
  - 点击文件进入刷题
  - 每项右侧的删除按钮只移除 `config.json` 里的目录记录，不会删除目录或题目文件
- 刷题
  - 单选 `single_choice`
  - 多选 `multiple_choice`
  - 判断 `true_false`
  - 填空/解释 `fill_blank`（展示答案后由用户自判）
  - 题目上方显示该题累计「已作答 / 答错」次数
  - 题目配图：JSON 的 `image` 非空时，从**题库 JSON 所在目录**加载同名图片；选择题显示在选项下方，填空/解释题紧跟题干。文件缺失或无法解码时显示占位框并标出文件名
- 统计与持久化
  - 每题判分后更新内存统计，并写一次文档目录下的工作副本
  - 整份做完、App 进入后台、页面销毁时，把工作副本回拷到题库所在文件夹
- 配置
  - `config.json` 保存 App 版本、题库目录列表、连续打卡天数和上次打卡日期
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

这样设计的原因：题目只有约 100 道，整份 JSON 很小，不需要数据库或增量写；所有答题过程中的写入都发生在 App 私有目录，只有最后同步时才碰用户目录，失败也不会影响继续刷题。

## 目录结构

```text
lib/
├── main.dart                       # 入口、主题、启动时加载配置
├── models/
│   ├── question_bank.dart          # 题库/题目/选项/统计/题型枚举
│   └── question_bank_file.dart     # 题库文件（名称 + 路径）
├── services/
│   ├── app_config.dart             # config.json 读写、题库目录全局 notifier
│   ├── question_bank_storage.dart  # 复制/读取/保存/回拷题库文件
│   └── storage_permission.dart     # Android 存储权限检查与申请
├── screen/
│   ├── main_screen.dart            # 底部导航 + IndexedStack
│   ├── home_page.dart              # 随机背景 + 打卡卡片
│   ├── question_bank_page.dart     # 目录选择、扫描、题库列表
│   ├── practice_page.dart          # 刷题界面与答题逻辑
│   └── me_page.dart                # 占位
└── widgets/
    ├── page_placeholder.dart       # 占位页面（仅 ME 还在用）
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
  "appVersion": "1.0.0",
  "questionBankDirs": [],
  "clockOnNum": 0,
  "lastClockOnDate": ""
}
```

字段说明：

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `appVersion` | string | App 版本，默认 `1.0.0`，目前只作为记录 |
| `questionBankDirs` | string[] | 题库目录的绝对路径列表 |
| `clockOnNum` | int | 连续打卡天数，默认为 `0`；昨天打过则 +1，断签或首次打卡重置为 1 |
| `lastClockOnDate` | string | 上次打卡日期，格式 `yyyy-MM-dd`，空字符串表示从未打卡 |

已有旧配置没有 `lastClockOnDate` 时，会按空字符串处理，下一次打卡会从 1 重新开始。

`appVersion` 目前是代码里写死的默认值，不是安装包真实版本；要精确记录需要用 `package_info_plus` 读取后调用 `AppConfig.setAppVersion()`。

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
| `AppConfig.appVersion` | 读取当前版本 |
| `AppConfig.clockOn` | 读取当前累计打卡天数 |
| `AppConfig.clockOnNotifier` | 打卡天数的 `ValueNotifier<int>`，首页监听它刷新 |
| `AppConfig.lastClockOnDate` | 上次打卡日期，格式 `yyyy-MM-dd` |
| `AppConfig.hasCheckedInToday` | 今天是否已经打过卡 |
| `AppConfig.checkInToday()` | 完成今天打卡：今天已打返回 false；昨天打过则 +1；断签重置为 1 |
| `AppConfig.setClockOn(int)` | 只改天数、不改日期，仅用于调试，不要拿来做打卡 |
| `AppConfig.questionBankDirs` | 题库目录的只读快照 |
| `AppConfig.questionBankDirsNotifier` | 题库目录的 `ValueNotifier<List<String>>`，界面监听它自动刷新 |
| `AppConfig.setAppVersion(String)` | 修改版本并落盘 |
| `AppConfig.setQuestionBankDirs(List<String>)` | 整体替换目录并落盘 |
| `AppConfig.addQuestionBankDir(String)` | 追加目录（去重）并落盘 |
| `AppConfig.removeQuestionBankDir(String)` | 删除目录并落盘 |
| `AppConfig.save()` | 手动保存，一般不需要 |

### QuestionBankStorage（`lib/services/question_bank_storage.dart`）

| 成员 | 说明 |
| --- | --- |
| `QuestionBankStorage(sourcePath:, fileName:)` | 绑定一个源题库文件 |
| `load()` | 复制源文件到文档目录，读取并解析成 `QuestionBank` |
| `save(QuestionBank)` | 把整份题库写回工作副本，内部串行队列 |
| `syncBack()` | 把工作副本回拷到源文件，返回是否成功 |
| `workingPath` | 工作副本路径，调试用 |

### StoragePermission（`lib/services/storage_permission.dart`）

| 成员 | 说明 |
| --- | --- |
| `isGranted()` | 只检查是否已有权限，不弹窗 |
| `ensure(context)` | 无权限时弹说明并跳系统设置，返回最终是否可用 |

### 页面

| 类 | 说明 |
| --- | --- |
| `MainScreen` | 底部导航 + `IndexedStack`，保存当前选中的题库 |
| `MainScreen._openBank(QuestionBankFile)` | 点击题库后的回调：保存选中项并切到刷题 tab |
| `QuestionBankPage(onOpenBank:)` | 扫描目录，点击文件时把 `QuestionBankFile` 交给父级 |
| `PracticePage(bank:)` | 接收题库并完成加载、答题、统计、回拷 |
| `PagePlaceholder(title:, icon:)` | ME 的占位页 |

## 页面切换与状态

- 四个页面放在 `IndexedStack` 里，切 tab 不销毁页面，因此扫描结果和刷题进度会保留；
- `MainScreen` 持有 `_selectedBank`，每次重建把最新的 `bank` 传给 `PracticePage`；
- `PracticePage` 在 `didUpdateWidget` 里比较 `oldWidget.bank?.path` 和 `widget.bank?.path`，路径变化才重新加载；
- 题库页通过 `onOpenBank` 回调把选择交给父级，自己不直接操作刷题页；
- 刷题页用 `_loadToken` 防止旧的异步加载覆盖新加载。

## 继续开发指南

### 1. 完成 ME 页

Home 已经是完整实现（`home_page.dart`：随机背景 + 打卡卡片 + 语录卡），不再走占位页。
ME 目前仍直接用 `PagePlaceholder`，替换 `MePage.build` 即可，例如读取题库目录数量：

```dart
ValueListenableBuilder<List<String>>(
  valueListenable: AppConfig.questionBankDirsNotifier,
  builder: (context, dirs, _) => Text('题库目录：${dirs.length} 个'),
)
```

ME 页可以放设置、关于、导入导出等入口。改完后 `page_placeholder.dart` 就没有使用者了，可以整个删掉。

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
final storage = QuestionBankStorage(sourcePath: path, fileName: name);
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

路径由 `QuestionBankStorage.sourceDir`（源 JSON 所在目录）解析，而不是文档目录里的工作副本——
因为 `load()` 只复制 JSON，图片不会跟着复制。

## Android 权限与平台限制

`android/app/src/main/AndroidManifest.xml` 声明了：

- `READ_EXTERNAL_STORAGE`（maxSdk 32）
- `WRITE_EXTERNAL_STORAGE`（maxSdk 29）
- `MANAGE_EXTERNAL_STORAGE`（Android 11+）

应用通过 `StoragePermission.ensure` 引导用户授予「所有文件访问」。

注意：

- `MANAGE_EXTERNAL_STORAGE` 属于高风险权限，Google Play 审核很严，个人自用/侧载没问题；
- 如果以后要上架，建议改成 SAF 持久化 URI 或把题库放在 App 专属目录；
- iOS / 桌面端能运行 UI，但路径和权限策略不同，需要单独适配；
- 即使有 MANAGE 权限，`Android/data/<其他包名>` 和 `obb` 仍不可访问。

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
- **填空/解释由用户自判**：没有自动判分，统计依赖“答对了 / 答错了”按钮；
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
