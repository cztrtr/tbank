import 'question_bank_file.dart';

/// 错题本列表里的一本。
class MistakeBookInfo {
  const MistakeBookInfo({
    required this.name,
    required this.path,
    required this.groupName,
    required this.total,
    required this.completed,
    this.plugin,
  });

  /// 本子名，例如 `Alpha`。
  final String name;

  /// JSON 文件的绝对路径。
  final String path;

  /// 所属分组（题库文件夹名，例如 `组织学`）；空字符串表示老数据的「未分组」。
  final String groupName;

  /// 处理这本错题的插件 id；null 表示老本子，按 standard 处理。
  final String? plugin;

  /// 题目总数。
  final int total;

  /// 已完成的题目数（mistakeScore 减到 0 的那些）。
  final int completed;

  /// 整本是否都已完成。
  bool get isFinished => total > 0 && completed == total;

  /// 转成练习页需要的题库文件描述。
  ///
  /// `name` 只用于 Documents 目录下的工作副本，加「错题本-组名-本名」前缀
  /// 避免和用户自己的同名题库、或其它组的同序号本子撞车；
  /// 源文件始终是 `path`，配图目录就是本子所在文件夹（`path` 的父目录）。
  QuestionBankFile toBankFile(String directoryPath) => QuestionBankFile(
    name: _workingCopyName,
    uri: path,
    directoryRef: directoryPath,
    directoryName: groupName.isEmpty ? '错题本' : '错题本·$groupName',
  );

  /// 工作副本的文件名。
  ///
  /// 分组名来自题库文件夹名：Android 上 SAF 的显示名可能带多级路径
  /// （例如 `tbankQuestion/医用物理学`）。把它原样拼进文件名，
  /// `docs/错题本-tbankQuestion/医用物理学-Alpha.json` 就会被当成
  /// 两级目录，父目录不存在，练习页读工作副本时报
  /// `No such file or directory`。这里统一把路径分隔符和 Windows 上的
  /// 非法字符替换掉，保证工作副本永远落在 Documents 目录的第一层。
  String get _workingCopyName {
    final String prefix = groupName.isEmpty ? '' : '$groupName-';
    final String raw = '错题本-$prefix$name.json';
    return raw.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  }
}
