/// 一个题库文件。
///
/// 题库可能来自两种存储：
/// - Android：SAF 授权的目录，`uri` 是 `content://` 形式的 document URI；
/// - 桌面（Windows）：普通文件系统，`uri` 是绝对路径。
///
/// 上层统一通过 `BankIo` 访问，不直接碰文件系统。
///
/// 递归扫描时，[directoryRef] 是文件**实际所在**的目录（子目录文件的配图、
/// 回拷都看它），[sourceDirectoryRef] 是用户添加的那个根目录（删除配置记录、
/// 管理页分组看它）。根目录下的文件两者相同。
class QuestionBankFile {
  const QuestionBankFile({
    required this.name,
    required this.uri,
    required this.directoryRef,
    this.sourceDirectoryRef,
    this.subDirectory = '',
    this.directoryName,
  });

  /// 文件名，例如 `高数第一章.json`。
  final String name;

  /// 文件引用：SAF 的 document URI，或桌面端的绝对路径。
  final String uri;

  /// 文件实际所在目录的引用。
  ///
  /// 题目配图、工作副本回拷都以它为基准；递归扫描到子目录时，
  /// 这里是子目录而不是用户添加的根目录。
  final String directoryRef;

  /// 用户添加的根目录引用；根目录文件为 null（视为等于 [directoryRef]）。
  ///
  /// 删除目录记录、管理页分组要用它，否则会把子目录误当成一个新添加的目录。
  final String? sourceDirectoryRef;

  /// 相对根目录的子目录名；根目录下的文件为空字符串。
  ///
  /// 只递归一层，所以这里最多一段，不含路径分隔符。
  final String subDirectory;

  /// 目录展示名；为空时由目录引用推导。
  final String? directoryName;

  /// 用户添加的根目录；没有递归信息时退回 [directoryRef]。
  String get rootDirectoryRef => sourceDirectoryRef ?? directoryRef;

  /// 界面展示名：去掉 `.json` 后缀（大小写不敏感）。
  ///
  /// 只影响 UI，真实文件名仍用 [name]，工作副本和回拷逻辑不变。
  String get displayName {
    if (name.length > 5 && name.toLowerCase().endsWith('.json')) {
      return name.substring(0, name.length - 5);
    }
    return name;
  }

  /// 带子目录前缀的展示名，例如 `线代/第一章`。
  ///
  /// 管理页的列表、练习页标题、搜索都用它，避免不同子目录下的同名题库
  /// 在界面上分不清。
  String get displayPath =>
      subDirectory.isEmpty ? displayName : '$subDirectory/$displayName';
}
