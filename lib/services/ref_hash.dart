/// 题库来源的稳定哈希，供工作副本、练习进度等按来源隔离的文件命名使用。
///
/// 不用 `String.hashCode`：它带进程随机种子，重启后会变，导致每次启动
/// 都换一个目录。这里只用 `codeUnits`，同一个引用在任何平台、任何进程里
/// 都得到同一个结果；FNV-1a + djb2 拼成 16 位十六进制，碰撞概率可忽略。
String stableRefHash(String ref) {
  int fnv = 0x811c9dc5;
  int djb2 = 5381;
  for (final int code in ref.codeUnits) {
    fnv = ((fnv ^ code) * 0x01000193) & 0xFFFFFFFF;
    djb2 = ((djb2 * 33) ^ code) & 0xFFFFFFFF;
  }
  return '${fnv.toRadixString(16).padLeft(8, '0')}'
      '${djb2.toRadixString(16).padLeft(8, '0')}';
}
