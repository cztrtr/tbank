/// 一个题库文件。
///
/// 题库管理页只把「文件名 + 完整路径」传给刷题页，
/// 真正的题目内容由 QuestionBankStorage 在刷题页加载。
class QuestionBankFile {
  const QuestionBankFile({required this.name, required this.path});

  /// 文件名，例如 `高数第一章.json`，用于列表展示和文档目录副本命名。
  final String name;

  /// 源文件完整路径，例如 `/storage/emulated/0/.../高数第一章.json`。
  final String path;
}