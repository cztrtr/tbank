# TBank

一个使用 Flutter 编写的本地题库练习 App。

题库是普通的 `.json` 文件，可以放在手机存储的任意目录；App 负责扫描目录、读取题目、记录每题累计作答/答错次数，并把统计回写到原文件。

> 当前状态：题库管理、练习（含题目配图、AI 判分 / AI 解析）、本地统计、错题本、
> 首页打卡卡片与语录卡、设置页均已实现。设置页目前只有 DeepSeek 密钥一项。
> 平台支持 Android（SAF 授权目录）与 Windows 桌面（普通文件路径）。
> iOS / Linux / macOS / Web 平台目录已移除；需要时用
> `flutter create --platforms=ios,linux,macos,web .` 重新生成模板。

## 功能

- 底部导航：`首页` / `管理` / `练习` / `我的`
- 首页
  - 每次启动从 `assets/images/home_bg/` 随机选择一张背景图，使用 `BoxFit.cover` 等比铺满
    （图片已压缩成 WebP，并按屏幕宽度解码，控制内存占用）
  - 顶部居中的圆角正方形打卡卡片（半透明毛玻璃）：显示「打卡」、累计天数、日期
  - 点击卡片后文案变为 `HELLO`、天数隐藏、日期放大，1 秒后卡片淡出离场；同时按连续打卡规则更新 `clockOnNum` 和 `lastClockOnDate`
  - 如果今天已经打过卡，卡片显示「已打卡」、保留天数，但不可再次点击；**只在本次启动展示 3 秒，随后自动淡出并从布局中移除**（语录卡随之上移）
  - 打卡卡片下方是一张半透明圆角「语录卡」：启动时从 `assets/texts/quotes.txt` 随机取一句；点击换下一句，且不会连续两次显示同一句
  - 语录文件的格式：一行一句，空行忽略，`#` 开头的行是注释
- 题库管理
  - 右上角 `+` 调起系统目录选择器
  - 多目录**并发扫描**；右上角搜索按钮可按题库名称筛选
  - 扫描所选目录下的 `.json`，并向下多看**一层子目录**（跳过 `.` 开头的隐藏目录）；
    按「父文件夹 → 子文件夹 → 题库」三级展示，子目录里的题库显示为 `子目录/题库名`：
    父文件夹取每个目录引用的上一层（`BankIo.parentOf`），同一父目录下添加的多个子目录归到一组；
    解析不出父级时退化成两级，不重复显示标题
  - 子目录题库在统计页和错题本里按「根目录名/子目录名」分组；配图、回拷仍指向文件实际所在子目录
  - App 内置 AI 题库支持两级目录（`Question/<主题>/<子主题>`），与用户目录一起按同一规则展示
  - 点击文件进入练习
  - 子文件夹标题右侧的删除按钮只移除 `config.json` 里的目录记录，不会删除目录或题目文件
- 练习
  - 单选 `single_choice`
  - 多选 `multiple_choice`
  - 判断 `true_false`
  - 填空/解释 `fill_blank`（可输入文字或拍照/选择作答图片；配置了 DeepSeek 密钥时由 AI 判 0-10 分，低于 6 分判错；未配置时退回「展示答案 + 自判」）
  - 所有题型答完后都有左侧「AI 解析」、右侧「下一题」；选择题讲正确答案与其它选项，主观题给解题步骤并点评学生作答（文字 + 作答图片）；解析结果显示在页面最下方的独立框里
  - 题目上方显示该题累计「已作答 / 答错」次数
  - 题目配图：JSON 的 `image` 非空时，从**题库 JSON 所在目录**加载同名图片；选择题显示在选项下方，填空/解释题紧跟题干。文件缺失或无法解码时显示占位框并标出文件名
  - 断点续练：每次答题/切题后把当前题号、已答结果和本次计数写进 App 私有目录的 `progress/`；
    退出或重启后重新打开同一题库会恢复进度，整套做完或题库题目增删/换序后自动放弃旧进度
- 错题本
  - 「我的 → 错题本」进入二级页面：先列出已有本子（秒开），再在后台扫描所有题库目录，
    把 `stats.wrongCount > 0` 的题复制到 App 私有目录的 `mistakes/`；完成后刷新列表并提示新增数量
  - **按题库文件夹分组**：同一 App 添加目录下的错题收进 `mistakes/<文件夹名>/`（如 `mistakes/组织学/`），不同文件夹互不混合；老版本直接放在根目录的本子显示为「未分组」
  - 每组 25 题一本，命名顺序：24 个希腊字母（Alpha…Omega）→ 加序号再来一轮（Alpha 2、Beta 2……），共 24 个一轮；不再使用汉字命名
  - 题目 `id` 重编号为 `C001`…（组内独立编号），并写入 `origin`（App 生成的稳定随机题目 id，`q_` 前缀）用于去重、`mistakeScore`（初始 3）
  - 配图复制到本子所在分组目录并按新编号重命名，错题本不依赖原题库目录
  - 作答时 `mistakeScore` 答对 -1、答错 +1，减到 0 视为完成；**题目保留不移除**，列表显示「已完成 / 未完成」
  - 列表按「父文件夹 → 题库子文件夹 → 错题本」三级展示：分组名仍是题库文件夹名，
    父级由当前题库目录配置反查 `BankIo.parentOf` 得到（目录被移除/改名的分组退化成自己的分组名）
  - 列表里可以删除整本（连同配图）；被删题目的 `origin` 写入 `mistakes/deleted_origins.json`，之后不再自动收集
  - 错题本内作答不回写原题库统计
- 快速开始
  - 入口在「我的」页顶部，页面读取随包发布的 `assets/texts/quick_start.md` 展示
  - 内容覆盖上手步骤（打卡/添加题库/安装插件/作答/错题本/配置 DeepSeek API/AI 出题/应用更新），不写技术细节
  - 渲染器只支持用到的少量 Markdown：标题、无序列表、`**粗体**`、`` `行内代码` ``
- 学习统计
  - 入口在「我的 → 学习统计」
  - 扫描所有用户题库目录 + App 内置 AI 题库（含二级目录），汇总总题数、作答次数、答错次数与正确率
  - 按题库文件夹分组显示，并列出答错次数最多的前 5 道题；顶部显示连续打卡天数
  - 单个题库文件损坏时跳过，不影响整体统计
- AI 出题
  - 入口在「我的 → AI 出题」，需要已配置 DeepSeek 密钥
  - 先选**出题插件**，页面只列出该插件 manifest 的题型；再选题型、输入主题与要求、题目数量（5~100）
  - standard 的 manifest 声明四种数据题型：单选 / 多选 / 判断 / 填空（说明里覆盖名词解释、解答、证明）
  - 生成 Prompt 由「用户要求 + 插件 typeDescriptions + typeSchemas/typeExamples」组成，App 不再硬编码题型说明
  - 按题型配额生成：每个已选题型至少 1 道，返回不足或 `pluginData` 校验失败会立即重试，默认每题型最多 4 次；全部覆盖后才落盘
  - 每本最多 25 道，保存到 `Question/<主题>/<主题>-<时间戳>-<批次>.json`；根节点写 `plugin` / `pluginVersion`
  - 标准题型继续校验选项数量/答案 key；自定义题型只校验通用字段，`pluginData` 按插件 schema 校验
  - 页面下方列出已生成题库，答错的题同样进错题本；`Question/` 下的题库也会显示在「管理」页
- 拍书出题
  - 入口在「我的 → 拍书出题」，拍照或从相册选 1~3 张图片（压缩到长边 1600）
  - 图片可以是题目或知识点讲解；出题插件、题型、schema 与 AI 出题共用
  - 保存位置可自定义：`Question/<一级目录>[/<二级目录>]/<文件名>.json`；
    二级目录与文件名可留空，自动用「一级目录-时间戳」命名，多批时追加 `-2`、`-3`
  - **不会覆盖已有题库**：`reserveBaseName()` 预留基名，`saveBatchTo()` 落盘时再查一次
  - 页面下方列出 `Question/` 里已有的全部题库，二次确认后可彻底删除（连同空目录）
- AI 变式出题
  - 入口在「管理」页每个题库右侧的 ✨ 按钮
  - 读取题干/选项/答案/解析后，先调 AI 归纳**具体知识点**，再按源题库所属插件的题型配额重新出题
  - 题型、说明、schema 都来自源题库的插件；生成文件根节点继承源题库的 `plugin` / `pluginVersion`
  - 新题保存回原题库目录，文件名按希腊字母递增：`<原名>-alpha.json` → `-beta.json`…；自动跳过已占用名字
  - 默认题数与原题库一致（上限 100），id 从 `Q001` 重编、stats 归零、`image` 置空
  - 归纳知识点时最多均匀采样 60 道原题，避免提示词过长
- 应用更新
  - 入口在「设置」页：填 cpolar 地址 → 下载 `app-release.apk` → 拉起系统安装器
  - 地址支持完整 APK 链接、只填域名（自动补 `/app-release.apk`）、不带协议（自动补 https）
  - Android 下载到缓存目录后，通过 FileProvider 交给系统安装器；桌面端只下载到下载目录
  - 未授予「安装未知应用」时会跳到系统授权页并提示用户重试
- 统计与持久化
  - 每题判分后更新内存统计，并按 400ms 防抖写一次文档目录下的工作副本
  - 整份做完、App 进入后台、页面销毁时立即 flush 并回拷到题库所在文件夹
  - 回拷失败时保留 `.dirty` 标记；下次打开题库先补回拷，仍失败就读副本，避免统计被旧源文件覆盖
- 配置
  - `config.json` 保存题库目录列表、连续打卡天数、上次打卡日期和 DeepSeek API Key（base64）
  - 配置和目录变化通过 `ValueNotifier` 全局广播

## 数据流

```text
题库文件夹里的 xxx.json
        │  QuestionBankStorage.load()
        │  1. 复制到 文档目录/banks/<来源哈希>/<文件名>（每个来源独立副本）
        ▼
工作副本 + .dirty 标记（save 后出现）
        │  2. 解析
        ▼
内存中的 QuestionBank
        │  3. 每题判分后 QuestionStats 递增；400ms 防抖写副本
        ▼
工作副本写回（QuestionBankStorage.save）
        │  4. 完成 / 进后台 / 页面销毁 / 换题库时 flush
        ▼
回拷到题库文件夹里的原 xxx.json（syncBack）
```

这样设计的原因：题目只有约 100 道，整份 JSON 很小，不需要数据库或增量写；所有答题过程中的写入都发生在 App 私有目录，只有最后同步时才碰用户目录，失败也不会影响继续练习。

## 目录结构

```text
lib/
├── main.dart                       # 入口、主题、启动时加载配置
├── models/
│   ├── question_bank.dart          # 题库/题目/选项/统计/题型枚举 + QuestionCodec 编解码入口
│   └── question_bank_file.dart     # 题库文件（名称 + 引用 + 所属目录）
├── services/
│   ├── app_config.dart             # config.json 读写、全局 notifier
│   ├── question_bank_storage.dart  # 读取/保存/回拷题库文件（按来源隔离工作副本）
│   ├── bank_io.dart                # 存储访问统一入口（SAF / 文件路径）
│   ├── bank_repository.dart        # 题库扫描统一入口（用户目录 + AI 题库、去重、缓存）
│   ├── practice_progress.dart      # 断点续练：进度 JSON 的读写与清除
│   ├── ref_hash.dart               # 题库来源的稳定哈希（工作副本 / 进度文件命名）
│   ├── saf.dart                    # Android SAF 通道封装
│   ├── ds_api_service.dart         # DeepSeek 业务层（提示词/判分/解析/出题）
│   ├── ds_transport.dart           # DeepSeek HTTP 传输层（流式/非流式/SSE）
│   ├── ds_api_exception.dart       # DsApiException
│   ├── ai_question_generator.dart  # AI 出题：生成、校验、落盘到 Question/
│   ├── variant_question_generator.dart # AI 变式出题：读题库→归纳知识点→按希腊字母命名写回同目录
│   ├── update_service.dart         # 应用更新：下载 APK + 调起系统安装器
│   ├── plugin_manager.dart         # 插件目录、manifest、安装/卸载、配置读写
│   ├── plugin_runtime.dart         # 插件 WebView 运行时开关
│   ├── plugin_schema.dart          # pluginData 的轻量 JSON Schema 校验
│   └── mistake_books.dart          # 错题本收集、分本、计数
├── screen/
│   ├── main_screen.dart            # 底部导航 + IndexedStack
│   ├── home_page.dart              # 随机背景 + 打卡卡片
│   ├── question_bank_page.dart     # 目录选择、扫描、题库列表
│   ├── practice_controller.dart    # 练习状态机（题号/选择/判分/计数/断点）
│   ├── practice_persistence.dart   # 保存/防抖/回拷/断点
│   ├── practice_ai_service.dart    # AI 判分、AI 解析、题目配图读取
│   ├── answer_image_picker.dart    # 作答图片选择与压缩（4 张 / 5 MB / 10 MB）
│   ├── practice_question_view.dart # 原生单题 UI（测试/关闭插件运行时）
│   ├── practice_page.dart          # 练习页：加载、状态编排、完成页
│   ├── plugin_practice_view.dart   # 插件练习 WebView 宿主
│   ├── plugin_config_page.dart     # 插件 config.html 配置页宿主
│   ├── plugin_type_selector.dart   # 出题页的插件 + 题型选择器
│   ├── plugins_page.dart           # 插件管理页（导入/下载/卸载/齿轮）
│   ├── mistake_books_page.dart     # 错题本二级页面（先展示再后台收集）
│   ├── ai_generate_page.dart       # AI 出题页（插件题型 + 已生成题库）
│   ├── book_ai_generate_page.dart  # 拍书出题页（图片 + 插件题型）
│   ├── variant_generate_page.dart  # AI 变式出题页（源题库插件 + 知识点）
│   ├── me_page.dart                # 个人中心入口
│   ├── quick_start_page.dart       # 快速开始
│   ├── stats_page.dart             # 学习统计
│   └── settings_page.dart          # 设置页
├── widgets/
│   ├── quote_card.dart             # 首页语录卡
│   ├── question_image.dart         # 题目配图
│   └── math_text.dart              # LaTeX 公式混合文本
assets/plugins/standard/            # 内置 standard：manifest/HTML/JS/CSS/KaTeX/普惠体
docs/PLUGIN_DEVELOPMENT.md          # 第三方插件完整开发文档
```

CI 配置在 `.github/workflows/flutter.yml`：push / PR 时跑 `flutter analyze` 和
`flutter test --coverage`。

## 快速开始

环境要求：

- Flutter 3.47+ / Dart 3.13+
- Android SDK 36（`compileSdk` 使用 Flutter 默认值）
- JDK 17+
- Visual Studio 2022（仅构建 Windows 桌面版需要，需勾选「使用 C++ 的桌面开发」）

```bash
cd tbank
flutter pub get
flutter run
```

打包 APK：

```bash
# 通用包：一个 APK 含全部 ABI（约 60 MB）
flutter build apk --release

# 推荐发布：按 ABI 拆分，单个包约 25-29 MB（含普惠体和 KaTeX）
flutter build apk --release --split-per-abi
```

输出：

```text
build/app/outputs/flutter-apk/app-release.apk
build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk
build/app/outputs/flutter-apk/app-x86_64-release.apk
```

给真机分发时优先用 `app-arm64-v8a-release.apk`；模拟器或老设备再按架构选。
`--split-per-abi` 产物不能互相覆盖安装（签名相同但包名相同、ABI 不同），发布时保持同一架构更新。

签名由 `android/app/build.gradle.kts` 控制：存在 `android/key.properties` 时使用正式签名，
不存在时自动退回 debug 签名（方便本地直接 `flutter run --release`）。
debug 签名的包可以安装测试，但不能上架商店。

正式签名步骤：

1. 生成 keystore：

   ```bash
   keytool -genkey -v -keystore tbank-release.jks -keyalg RSA \
     -keysize 2048 -validity 10000 -alias tbank
   ```

2. 在 `android/key.properties` 写入（该文件和 keystore 已在 `.gitignore` 中）：

   ```properties
   storeFile=D:/keys/tbank-release.jks
   storePassword=你的仓库密码
   keyAlias=tbank
   keyPassword=你的密钥密码
   ```

3. 重新执行 `flutter build apk --release`，用 `apksigner verify --print-certs` 确认签名。

### Windows 桌面版

```bash
flutter build windows --release
```

输出目录：

```text
build/windows/x64/runner/Release/
```

该目录里的 `tbank.exe`、`flutter_windows.dll`、`data/` 必须一起分发，
打包时把整个 `Release/` 目录压成 zip 即可。桌面端不申请任何系统权限，
题库目录用 `file_picker` 选择，读写走普通文件路径（见下文「桌面端」）。

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
- **`id` 会被 App 替换成稳定随机 id**：添加题库目录时（以及进入错题本页兜底）扫描时，凡不是 `q_` 前缀的 id
  都会替换成 `q_` + 26 位随机串并回写原文件（`_migrateQuestionIds`），
  错题去重因此只认题目本身、不认文件位置；替换失败（无法写回）时该文件沿用旧 id；
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
| `load()` | 复制源文件到 `文档目录/banks/<来源哈希>/`，读取并解析成 `QuestionBank`；有 `.dirty` 时先补回拷，失败则读副本 |
| `save(QuestionBank)` | 把整份题库写回工作副本，内部串行队列；写成功后打 `.dirty` 标记 |
| `syncBack()` | 把工作副本回拷到源文件，成功清除 `.dirty`，返回是否成功 |
| `pendingSyncWarning` | 上次加载时发现未回拷成功的提示；没有则为 null |

### BankRepository（`lib/services/bank_repository.dart`）

题库扫描统一入口：并发列用户目录、合并 App 内置 AI 题库、按 uri 去重，
默认 2 秒缓存；`listAll(refresh: true)` 强制重扫。管理页、统计页共用。

### PracticeProgress（`lib/services/practice_progress.dart`）

断点续练的持久化：文件在 `App Support/progress/<来源哈希>.json`。

| 成员 | 说明 |
| --- | --- |
| `load(file, questionIds)` | 读取断点；题目 id 顺序不一致、文件损坏时返回 null |
| `save(file, progress)` | 写入当前题号、本次计数和已答结果 |
| `clear(file)` | 整套做完或重新开始时删除断点 |

### PracticeController（`lib/screen/practice_controller.dart`）

练习状态机：题目、当前题号、选中项、已答结果、本次计数。
`record(correct)` 记录判分，`goTo(index)` 恢复某题状态，`restart()` 从头开始，
`loadBank(bank, progress)` 换题库并按断点恢复。

### PracticePersistence（`lib/screen/practice_persistence.dart`）

练习页的保存与回拷：400ms 防抖写工作副本、错题本每题回写、完成/后台/离开时
flush + `syncBack()`，以及断点 `saveProgress` / `clearProgress`。
页面不再自己管 Timer 和串行队列。

### PracticeAiService（`lib/screen/practice_ai_service.dart`）

练习页的 AI 动作：读题目配图、主观题 `score`、`explain` 解析。
页面只保留 loading/错误状态和 UI。

### AnswerImagePicker（`lib/screen/answer_image_picker.dart`）

作答图片选择与压缩：最多 4 张、单张 5 MB、合计 10 MB，长边压到 1600。
校验失败抛 `AnswerImageException`，页面只负责提示。

### QuestionCodec（`lib/models/question_bank.dart`）

题库 JSON 编解码的唯一入口：`bankFromJson` / `bankToJson`、
`questionFromJson` / `questionToJson`、`statsFromJson` / `statsToJson`、
`decode(raw)` / `encode(bank)`、`encodeQuestions(questions)`。
以后加题目字段只改 `QuestionCodec` 和模型字段，不要在多个文件里各写一套
fromJson / toJson。

### Saf（`lib/services/saf.dart`）

Android Storage Access Framework 的 Dart 封装，对应原生 `tbank/saf` 通道
（实现见 `android/app/src/main/kotlin/com/example/tbank/MainActivity.kt`）。
所有 IO 在原生线程池执行后切回主线程，不阻塞 UI。

| 成员 | 说明 |
| --- | --- |
| `Saf.isSupported` | 是否 Android；桌面端为 false，走文件路径 |
| `Saf.pickDirectory()` | 弹系统目录选择器，返回可跨重启的 tree URI；取消返回 null |
| `Saf.listChildren(uri, extension:, recursive:)` | 列出目录下的文件；`recursive` 为 true 时向下扫一层子目录，条目带 `parentUri` / `subDirectory` |
| `Saf.readText(uri)` / `Saf.writeText(uri, text)` | 读写 UTF-8 文本，写入用 `wt` 模式会截断旧内容 |
| `Saf.readChildBytes(dirUri, name)` | 按文件名读子文件字节，题目配图用 |
| `Saf.writeChildText(dirUri, name, text)` | 在目录里新建/覆盖一个 JSON 文本文件（同名覆盖，否则 `createDocument` 新建），返回文档 URI；AI 变式题用 |
| `Saf.releasePermission(uri)` | 释放目录授权 |

### BankIo（`lib/services/bank_io.dart`）

存储访问的统一入口，把「SAF URI」和「桌面文件路径」收敛成同一套 API。
判断依据只有一条：引用是否以 `content://` 开头。

| 成员 | 说明 |
| --- | --- |
| `listJsonFiles(dirRef, recursive:)` | 列出目录下的 `.json`；`recursive` 为 true 时额外包含一层子目录，两种存储都支持 |
| `readText(fileRef)` / `writeText(fileRef, text)` | 读写题库 JSON，读取时自动去掉 BOM |
| `readSiblingBytes(dirRef, name)` | 读同级文件字节（题目配图） |
| `writeSiblingText(dirRef, name, text)` | 在目录里新建/覆盖 JSON 文件（SAF 走原生 `createDocument`，桌面直接写路径） |
| `releaseDirectory(dirRef)` | 释放 SAF 授权；桌面端空操作 |
| `displayNameOf(dirRef)` | 从引用推导展示名，例如 `content://…/tree/primary%3ABooks` → `Books` |

### DsApiService（`lib/services/ds_api_service.dart`）

DeepSeek 对话接口（OpenAI 兼容协议）的封装，模型固定为 `deepseek-flash`。
API Key 从 `AppConfig.dsApiKey` 读取，未配置时抛 `DsApiException`。
HTTP 传输（非流式 / 流式 / SSE 解析 / 错误翻译）拆在 `ds_transport.dart`，
异常类型拆在 `ds_api_exception.dart`；`DsApiService` 只保留提示词与业务解析。

| 成员 | 说明 |
| --- | --- |
| `ask(content, stream:, thinking:)` | 通用问答；`thinking` 控制是否启用思考模式 |
| `scoreAnswer(question:, standardAnswer:, userAnswer:, imageBytes:, answerImages:)` | App 内置评分 Prompt 与 0-10 分解析，供填空/解释题判分；`imageBytes` 是题目配图，`answerImages` 是学生上传的作答图片（可多张） |
| `complete(prompt:, images:)` | 独立 AI 补全：Prompt 由插件提供，App 只负责鉴权/发送/返回文本；固定模型、非流式、Prompt ≤20 KB、最多 6 图 |
| `explainQuestion(question:, options:, correctAnswer:, imageBytes:)` | 旧解析入口：App 内置 Prompt，保留给原生回退和旧插件 |
| `extractKnowledgePoints(bankName:, questionsText:)` | 通读题库摘要，归纳知识点，返回 `List<String>` |
| `generateQuestionsFromKnowledge(topic:, knowledgePoints:, types:, count:)` | 围绕知识点生成变式题，返回原始 JSON 文本 |
| `parseKnowledgePoints(raw)` | 解析知识点 JSON，容忍代码围栏与多余文字 |
| `sseDelta(line)` | 转发到 `DsTransport.sseDelta`，解析一行 SSE，区分正文 `content` 与思考过程 `reasoning_content` |

说明：

- 传了 `imageBytes` 时按「文本 + `image_url` 内容块」发送（`_withImages`），MIME 按文件头判断
- 所有错误统一转成 `DsApiException`，带中文提示和 HTTP 状态码
- 没有引入 `dart:io`，保持与平台无关的纯 Dart 依赖，便于复用

### MistakeBooks（`lib/services/mistake_books.dart`）

错题本的收集与统计。文件放在 App Support 目录的 `mistakes/` 下，**按题库文件夹分组**：
`mistakes/<文件夹名>/Alpha.json`，配图按错题编号重命名后放在本子同一目录；
`deleted_origins.json` 在根目录，全局共享。老版本直接放在根目录的本子归为
「未分组」（组名空字符串），列表里排最后。

| 成员 | 说明 |
| --- | --- |
| `perBook` | 一本最多 25 题 |
| `initialScore` | 收进错题本时的初始 `mistakeScore`（3） |
| `directory()` | 返回 `mistakes/` 目录，不存在则创建 |
| `list()` | 递归列出所有分组的本子（含所属组名），按「组名 + Alpha…Omega」排序 |
| `collectFromBanks()` | 扫描所有题库，把 `wrongCount > 0` 且未收集过的题按题库文件夹分组复制进来（组内分本/编号），返回新增数 |
| `migrateAllBankIds()` | 首帧之后异步迁移所有已添加目录下的题库 id（幂等；成功后写一次性标记，后续启动只检查标记） |
| `migrateBankIdsInDirectory(dir)` | 添加题库目录时立即迁移该目录下所有题库的题目 id（幂等） |
| `resetAll()` | 设置页「重置错题本」按钮调用的手动重置：删除所有错题本（JSON + 配图）并清空删除史 |
| `deleteBook(book)` | 删除一本错题本及其配图，并把题目的 `origin` 记入删除清单 |

去重键是 `origin`：**收录时直接记题目 id**。题目 id 由 App 预先迁移成
`q_` 前缀的稳定随机串（与文件位置无关），老版本记录的
`'<原题库文件引用>#<原题 id>'` 会在收集时按 `旧键 → 新键` 映射自动迁移
（原文件回写失败时新收录仍用旧格式，去重时新旧键都查，保证不重复收集）。
编号 `C001` 在组内独立递增（从该组已有本子的最大编号继续）。

迁移时机：App 首帧之后（`main()` 里 `addPostFrameCallback` 调用
[`migrateAllBankIds`](lib/services/mistake_books.dart)）、
添加题库目录时（[`migrateBankIdsInDirectory`](lib/services/mistake_books.dart)）与
进入错题本页（`collectFromBanks`）各做一次，均幂等。
除了用户添加的目录，启动与收集还会额外覆盖 App 内置的 AI 出题目录
（`Question/<主题>`），保证两边的题目 id 与错题去重键一致。
首次升级启动会读一遍所有题库文件；成功后写 `id_migration_v1.done` 标记，
之后的启动只做一次 `exists()` 检查，不再扫描，冷启动不受题库数量影响。
错题本重置由设置页「重置错题本」按钮手动触发
（[`resetAll`](lib/services/mistake_books.dart)）：删除 `mistakes/` 下所有
错题本 JSON 与配图，并删除 `mistakes/deleted_origins.json`；
不做自动执行，也不写任何标记，点一次执行一次。
本子名从 Alpha…Omega 里取**当前未被占用**的第一个（[`_nextName`](lib/services/mistake_books.dart)），
删除中间的某本后新建不会重名覆盖。被删除的 `origin` 存在 `mistakes/deleted_origins.json`，
`collectFromBanks()` 会跳过它们，避免删完下次进入又自动收回来。

### 页面

| 类 | 说明 |
| --- | --- |
| `MainScreen` | 底部导航 + `IndexedStack`，保存当前选中的题库 |
| `MainScreen._openBank(QuestionBankFile)` | 点击题库后的回调：保存选中项并切到练习 tab |
| `QuestionBankPage(onOpenBank:)` | 扫描用户添加的目录 + 内置 AI 出题目录（`Question/`），点击文件时把 `QuestionBankFile` 交给父级；每行右侧 ✨ 进入 AI 变式出题 |
| `PracticePage(bank:)` | 接收题库并完成加载、答题、统计、回拷 |
| `MePage` | 个人中心，提供「快速开始」「学习统计」「错题本」「AI 出题」「拍书出题」「设置」六个入口 |
| `QuickStartPage` | 快速开始：读取 `assets/texts/quick_start.md` 并用简单 Markdown 排版展示 |
| `SettingsPage` | 设置页：DeepSeek 密钥、应用更新（下载 APK）、重置错题本 |
| `MistakeBooksPage` | 错题本二级页面：进入时收集并按题库文件夹分组列出各本 |
| `AiGeneratePage` | AI 出题：输入主题/要求生成 25 道题保存到 `Question/`，列出已生成题库 |
| `BookAiGeneratePage` | 拍书出题：拍照/相册识别题目或知识点，可自定义一级/二级目录与文件名 |
| `StatsPage` | 学习统计：汇总题数、作答/答错、正确率与错题排行 |
| `VariantGeneratePage(source:)` | AI 变式出题：读取源题库、归纳知识点、分批生成并按希腊字母递增命名写到同目录 |

### 组件（widgets）

| 组件 | 说明 |
| --- | --- |
| `QuoteCard` | 首页语录卡，从 `assets/texts/quotes.txt` 随机取句 |
| `QuestionImage` | 题目配图，从题库目录读字节渲染，缺失/损坏显示占位框 |
| `MathText` | 支持 LaTeX 的文本：解析 `$...$` / `\(...\)`（行内）与 `$$...$$` / `\[...\]`（独立公式），用 flutter_math_fork 渲染；无公式时退化为普通 `Text` / `SelectableText` |

## 页面切换与状态

- 四个页面放在 `IndexedStack` 里，切 tab 不销毁页面，因此扫描结果和练习进度会保留；
- `MainScreen` 持有 `_selectedBank`，每次重建把最新的 `bank` 传给 `PracticePage`；
- `PracticePage` 在 `didUpdateWidget` 里比较 `oldWidget.bank?.uri` 和 `widget.bank?.uri`，换了文件才重新加载；
- 题库页通过 `onOpenBank` 回调把选择交给父级，自己不直接操作练习页；
- 练习页用 `_loadToken` 防止旧的异步加载覆盖新加载。

## 继续开发指南

### 1. 扩展 ME 页

首页已经是完整实现（`home_page.dart`：随机背景 + 打卡卡片 + 语录卡）。
ME 目前有「错题本」「设置」两个入口（`me_page.dart` 里的列表项），
其余条目可以继续往下追加，例如关于、导入导出等：

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

第三方题型不需要改 App 的 `QuestionType` 枚举，走插件即可：

1. 在插件 `manifest.json` 的 `types` 里声明题型 id；
2. 补 `typeNames` / `typeDescriptions`，需要私有字段再补 `typeSchemas` / `typeExamples`；
3. 在插件 `index.html` / `app.js` 里渲染该题型，提交时调 `tbankSubmit`；
4. 私有字段放 `pluginData`，需要修改时调 `tbankUpdatePluginData`；
5. 打包 zip，在「设置 → 插件管理」安装。

只有要新增 **App 内置原生题型** 时，才需要改 `QuestionType`、`QuestionCodec` 和原生
`PracticeQuestionView`；详细插件协议见 [插件开发指南](PLUGIN_DEVELOPMENT.md)。

### 4. 修改判分 / 统计

- 选择题判分在 `PracticePage._submitChoice`，目前是“集合完全相等”；
- 插件题型的判分由插件通过 `tbankSubmit` 回传；
- 统计更新统一在 `_recordAnswer`，处理 `attemptCount` / `wrongCount`；
- 保存由 `PracticePersistence` 400ms 防抖写入工作副本，完成/后台/销毁/换题库时回拷；
- 断点保存在 `PracticeProgress`，不保存未提交的输入和作答图片。

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

`android/app/src/main/AndroidManifest.xml` 里有两条权限：

```xml
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.REQUEST_INSTALL_PACKAGES" />
```

`INTERNET` 是 AI 判分 / AI 解析访问 `https://api.deepseek.com` 用的，普通权限、安装时不弹窗。
`REQUEST_INSTALL_PACKAGES` 是「设置 → 应用更新」下载完 APK 后拉起系统安装器用的；
Android 8+ 首次使用还要用户在系统里打开「允许安装未知应用」，否则 App 会跳到授权页并提示重试。
构建产物里另有 AndroidX 自动合并的 `DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION`（非存储类，无需授权）。

> 注意：Flutter 只在 `src/debug` 和 `src/profile` 的模板 manifest 里自动加 `INTERNET`，
> **release 包必须在主 manifest 显式声明**。漏了的话手机端会报
> `网络请求失败：Failed host lookup: 'api.deepseek.com'`，而桌面端不受影响（Windows 没有这层权限控制）。
> 排查方法：`aapt2 dump permissions app-release.apk` 看有没有 `INTERNET`。

应用内更新的 APK 通过 `FileProvider`（authority 为 `<applicationId>.fileprovider`）共享，
路径配置在 `android/app/src/main/res/xml/update_file_paths.xml`，只放行缓存目录下的 `updates/`。

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

Windows 桌面仍然用普通文件路径：`BankIo` 检测到引用不以
`content://` 开头就走 `dart:io`，目录选择继续用 `file_picker`。

### 平台限制

- 授权是「按目录」的，不能跨目录访问；同一目录下的 `.json` 共用一份授权；
- 用户可能在系统设置里撤销授权，撤销后该目录会显示「读取失败」，
  移除记录再重新添加即可恢复；
- Android 上旧版本存的绝对路径已无法访问，升级后会提示「旧版目录记录已失效」，
  需要删除后重新添加（题库文件本身不受影响）；
- iOS / Linux / macOS / Web 平台目录已从仓库移除，工具链里不再包含对应 runner；
  重新加回时执行 `flutter create --platforms=ios,linux,macos,web .` 即可，`lib/` 代码不受影响。

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

- **强杀进程可能丢最后一次同步**：答完最后一题后 400ms 内的写入可能来不及，但副本旁的 `.dirty` 标记会在下次打开时补回拷；补不回去时读副本，不会冲掉统计；
- **断点续练不保存未提交的输入**：已提交题目的判分结果会恢复，主观题输入框里还没提交的文字、拍照图片不落盘；题库题目增删或换序后旧进度自动作废；
- **同一题库练完后再点一次不会自动重开**：`didUpdateWidget` 比较的是路径，路径没变不会重新加载；可以点完成页的“再练一遍”，或给选择加一个序号；
- **填空/解释的判分依赖 DeepSeek**：配置了 Key 时由 AI 打 0-10 分（低于 6 分判错），未配置或请求失败时退回“答对了 / 答错了”自判；AI 判分有模型波动，同一答案分数可能不完全一致；作答图片最多 4 张、单张 5 MB、合计 10 MB，Android 端会压缩到长边 1600px；
- **只递归一层子目录**：跳过 `.` 开头的隐藏目录，第二层以下的文件不会自动出现；需要更深时扩展 `BankIo.listJsonFiles` 的递归深度，并同步 Android 原生 `queryChildren` 的 `allowSubdirectories`；
- **删除目录记录会带走该目录下所有题库**：列表按文件展示，但删除操作移除的是整个目录记录，同一目录里的其它 `.json` 也会一起从列表消失（文件本身不删）；
- **`Question/` 里的题库在管理页删不掉**：它是 App 内置目录，没有 `config.json` 记录可移除；要彻底删除请到「拍书出题」页底部的「已生成的题库」列表操作（删除不可恢复，错题本里已收集的题目会保留）；
- **界面状态**：练习状态收在 `PracticeController`，其余页面状态仍由各页 State 持有；没有引入 Provider/Riverpod，跨页面共享只通过 AppConfig 的 notifier（题库列表另有 `BankRepository` 缓存）；
- **配图不会被复制**：`load()` 只复制 JSON 到文档目录，图片始终从题库所在目录读取。因此源目录被删除、改名或权限被收回后，图片会退化成「图片不存在」占位框（不影响答题）；
- **配图高度上限 320px**：超过这个高度的图会被等比缩放到 320 以内，长截图可能看不清；改 `QuestionImage.maxHeight` 即可；
- **assets 体积**：`assets/images/home_bg/` 的背景图已压缩为 WebP（约 2.8 MB），以后新增图片建议同样压缩后再放入。

## 插件系统

第三方插件的完整 manifest、桥接口、`pluginData`、配置页和示例见
[插件开发指南](PLUGIN_DEVELOPMENT.md)。

### 目录与清单

插件放在 App 私有目录的 `plugins/<id>/` 下，每个插件根目录必须有 `manifest.json`：

```json
{
  "id": "coding",
  "name": "代码测评",
  "version": "1.0.0",
  "apiVersion": 1,
  "types": ["coding"],
  "typeNames": {"coding": "代码题"},
  "typeDescriptions": {
    "coding": "代码题：correctAnswer 放参考代码，analysis 写关键步骤。"
  },
  "description": "可选"
}
```

`types` 是写入题目 `type` 的标识；`typeNames` 用于出题界面展示；
`typeDescriptions` 会原样传给 AI 出题服务，App 不再硬编码题型说明。
老插件没有后两个字段时，App 显示 id 并给通用出题说明。

内置 `standard` 随包发布，启动时由 `PluginManager.ensureBuiltin()` 把
`assets/plugins/standard/` 下全部资源（manifest、HTML/JS/CSS、KaTeX）同步到
插件目录；它不可卸载。

### 题库与错题本标记

- 题库 JSON 根节点：`"plugin": "standard"`（省略按 standard 处理）、
  `"pluginVersion": 1`；
- 一个题库只能由一个插件处理，题目内部不写 plugin；
- 错题本根节点同样写 `plugin`，一本只收同一插件的题；同一组下不同插件
  会各自分本，目录不拆，统计/完成度仍由 App 计算。

### 安装 / 下载 / 卸载

- 设置 → 插件管理：列出插件、导入本地 `.zip`、从网络下载 `.zip`、卸载；
- zip 内可以根目录直接放 `manifest.json`，也可以套一层 `<id>/`；
- 校验 id、版本、API 版本、types、zip 路径穿越、大小/文件数；
- 同名非内置插件覆盖，内置 `standard` 拒绝覆盖和卸载；
  但 `standard` 允许安装**更高版本** zip 做热更新，启动时不会被随包旧资源覆盖；
- 卸载不会删除题库/错题本，打开时提示安装对应插件。

### WebView 运行时

`PluginRuntime.enabled` 为 true 时，所有已安装插件的题库改用
`PluginPracticeView` 加载 `plugins/<id>/index.html`：

- Android：`webview_flutter`（官方 WebView）；
- Windows：`webview_windows`（WebView2，构建机需要把 `nuget.exe` 放进 PATH）；
- 内置 `standard` 的 `index.html` / `app.js` / `style.css` / KaTeX 随包发布，
  启动时复制到插件目录，公式离线渲染；

App 通过统一桥接提供：

| 能力 | 说明 |
| --- | --- |
| `window.__tbankReceive(context)` | 注入题目、选项、正确答案、统计、错题本剩余次数、主题色、题目配图 data URL、`pluginData` |
| `tbankSubmit` | 插件提交 `{correct, selected}`，App 更新统计/错题本 |
| `tbankUpdatePluginData` | `{pluginData: {...}}`，按题型 schema 校验后写回当前题 |
| `tbankNext` / `tbankPrevious` | 上一题 / 下一题 |
| `tbankAiComplete` | 插件自己拼 Prompt，App 只负责鉴权/发送/返回文本 |
| `tbankAiExplain` | 旧接口：宿主代调 AI 解析（App 内置 Prompt），保留兼容 |
| `tbankAiScore` | App 内置主观题评分 Prompt 并解析，返回 0-10 |
| `tbankReadBank` | 只读当前题库 JSON |
| `tbankReadImage` | 读题库目录里的图片，返回 data URL |
| `tbankFetch` | 宿主代理 http/https 请求（30s、1 MB 上限） |
| `tbankClipboardRead` / `tbankClipboardWrite` | 剪贴板读写 |
| `tbankPickImage` | 拍照/相册选图，返回 data URL |
| `tbankToast` | 插件请求显示宿主 SnackBar |

插件只负责渲染和判分逻辑；App 保留题库加载、统计、持久化、回拷和导航。
widget 测试默认关闭 `PluginRuntime.enabled`，走原生 `PracticeQuestionView`，
避免依赖 WebView 平台实现。

### 插件配置

第三方插件可以在根目录放一个固定的 `config.html` 作为配置页；插件管理页
每个插件右侧的齿轮会打开它。配置数据单独保存在插件根目录的
`config.json`，不写进 manifest，也不写进题库。

- `config.html`：配置页 UI；
- `config.json`：App 保存的配置对象；不存在时视为 `{}`；
- 插件升级时 App 会保留旧 `config.json`，卸载时随插件一起删除。

宿主加载配置页后调用：

```js
window.__tbankConfigReceive({
  plugin: { id, name, version, apiVersion, types },
  config: { /* 当前配置 */ }
})
```

配置页通过同一套 Promise 桥调用：

| 接口 | 参数 | 返回 |
| --- | --- | --- |
| `tbankConfigGet` | 无 | 当前配置对象 |
| `tbankConfigSet` | `{config: {...}}` | `true`，写回该插件自己的 `config.json` |
| `tbankToast` | `{message}` | `true` |

示例 `config.html` 里的桥：

```js
let seq = 0;
const pending = new Map();
function call(name, args = {}) {
  return new Promise((resolve, reject) => {
    const id = String(++seq);
    pending.set(id, { resolve, reject });
    const text = JSON.stringify({ id, name, args });
    if (window.TBankChannel) window.TBankChannel.postMessage(text);
    else window.chrome.webview.postMessage(text);
  });
}
window.__tbankResolve = (id, result) => {
  const p = pending.get(id); if (p) { pending.delete(id); p.resolve(result); }
};
window.__tbankReject = (id, message) => {
  const p = pending.get(id); if (p) { pending.delete(id); p.reject(new Error(message)); }
};
window.__tbankConfigReceive = ({ config }) => {
  // 用 config 渲染表单
};
// 保存：
// await call('tbankConfigSet', { config: { theme: 'dark' } });
```

### 插件题型与 AI 出题

AI 出题、拍书出题、变式出题都按插件题型工作：

1. 用户在出题页选择插件，页面只列出该插件 manifest 的 `types`；
2. App 把用户要求 + 插件 `typeDescriptions` 拼进生成 Prompt；
3. AI 返回的每道题 `type` 必须是该插件声明的 id；
4. 写入题库时根节点写 `plugin` / `pluginVersion`，题目保留原始 type；
5. 变式出题沿用源题库的插件和题型说明，生成文件写回同一个 `plugin`。

所以 App 只负责通用的“生成 JSON 题库”服务，题型语义由插件自己定义。
`standard` 的四种题型也通过同一套 manifest 元数据工作，没有特殊分支。

### 插件私有题目数据

插件可以在题目里使用 `pluginData` 保存自己的结构，App 不解释、只原样保留：

```json
{
  "id": "q1",
  "type": "coding",
  "question": "实现函数",
  "options": [],
  "correctAnswer": ["..."],
  "stats": {"attemptCount": 0, "wrongCount": 0},
  "pluginData": {"language": "dart", "code": "..."}
}
```

manifest 可按题型声明 schema/示例：

```json
{
  "typeSchemas": {
    "coding": {
      "type": "object",
      "required": ["language", "code"],
      "properties": {
        "language": {"type": "string"},
        "code": {"type": "string"}
      }
    }
  },
  "typeExamples": {
    "coding": {"language": "dart", "code": "void main() {}"}
  }
}
```

- 生成时 App 把 schema/示例一起给 AI；返回后用
  `PluginSchemaValidator` 校验，坏题丢弃并要求按题型重试；
- 生成按题型配额进行，每个已选题型至少 1 道，不足立即重试（默认每题型
  最多 4 次），全部覆盖后才落盘；
- 练习时插件上下文带 `question.pluginData`，可调用
  `tbankUpdatePluginData({pluginData: {...}})` 修改当前题私有数据；
- App 会按当前题型 schema 校验修改结果，通过后写回题库工作副本；
- 支持的关键字：type / required / properties / additionalProperties /
  items / enum / const / allOf / anyOf / oneOf / minLength / maxLength /
  minimum / maximum / minItems / maxItems / pattern；不支持 `$ref`。

## 开发约定

- 页面里尽量使用 `Theme.of(context).colorScheme`，不要把颜色写死；
- 异步操作之后使用 `context` 或 `setState` 前先检查 `mounted`；
- 题库文件读写统一走 `QuestionBankStorage`，不要在页面里直接 `File` 操作；
- 题库 JSON 的解析/序列化统一走 `QuestionCodec`，不要在页面或服务里另写一套；
- 题库目录扫描统一走 `BankRepository`，不要在页面里重复列目录；
- 配置读写统一走 `AppConfig`，不要绕过它直接改 `config.json`；
- 每道题的统计更新统一走 `_recordAnswer`，避免重复计数；
- 练习状态和状态迁移优先放进 `PracticeController`，保存/回拷放
  `PracticePersistence`，AI 动作放 `PracticeAiService`，页面只做渲染与编排；
- 提交前跑 `flutter analyze` 和 `flutter test`；CI（`.github/workflows/flutter.yml`）用同样两条命令；
- `analysis_options.yaml` 开启了 `strict-casts` / `strict-inference` / `strict-raw-types`，
  解析 JSON 时要显式判断类型，不要依赖隐式转换；
- 新增需要跨页面共享的状态时，优先复用 `ValueNotifier` 模式，而不是再引入一套状态管理。
