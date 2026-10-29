/// 一个题库文件。
///
/// 题库可能来自两种存储：
/// - Android：SAF 授权的目录，`uri` 是 `content://` 形式的 document URI；
/// - 桌面（Windows）：普通文件系统，`uri` 是绝对路径。
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

  /// 界面展示名：去掉 `.json` 后缀（大小写不敏感）。
  ///
  /// 只影响 UI，真实文件名仍用 [name]，工作副本和回拷逻辑不变。
  String get displayName {
    if (name.length > 5 && name.toLowerCase().endsWith('.json')) {
      return name.substring(0, name.length - 5);
    }
    return name;
  }
}
