/// 一个题库文件。
///
/// 题库可能来自两种存储：
/// - Android：SAF 授权的目录，`uri` 是 `content://` 形式的 document URI；
/// - 桌面（Windows，模板保留 macOS）：普通文件系统，`uri` 是绝对路径。
///
/// 上层统一通过 `BankIo` 访问，不直接碰文件系统。
class QuestionBankFile {
  const QuestionBankFile({
    required this.name,
    required this.uri,
    required this.directoryRef,
    this.directoryName,
  });

  /// 文件名，例如 `高数第一章.json`，同时作为文档目录下工作副本的名字。
  final String name;

  /// 文件引用：SAF 的 document URI，或桌面端的绝对路径。
  final String uri;

  /// 所属目录引用（就是存进 config.json 的那一条）。
  ///
  /// 移除目录、定位题目配图都要用到它。
  final String directoryRef;

  /// 目录展示名；为空时由目录引用推导。
  final String? directoryName;
}
