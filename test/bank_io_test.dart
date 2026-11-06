import 'package:flutter_test/flutter_test.dart';
import 'package:tbank/services/bank_io.dart';

/// 管理页 / 错题本页按「父文件夹 → 子文件夹」分组时用的父级解析。
void main() {
  group('BankIo.parentOf 桌面路径', () {
    test('取上一层目录名', () {
      final ({String key, String label})? parent = BankIo.parentOf(
        r'D:\TR\tbank\tbankQuestion\大学物理-震动、波动和声',
      );
      expect(parent, isNotNull);
      expect(parent!.label, 'tbankQuestion');
      expect(parent.key, 'path:D:/TR/tbank/tbankQuestion');
    });

    test('正斜杠、尾部分隔符都能处理', () {
      expect(BankIo.parentOf('D:/题库/高数/')?.label, '题库');
      expect(BankIo.parentOf('D:/题库/高数')?.label, '题库');
      expect(
        BankIo.parentOf('D:/题库/高数')?.key,
        BankIo.parentOf('D:\\题库\\高数\\')?.key,
      );
    });

    test('盘根和单段路径没有父级', () {
      expect(BankIo.parentOf(r'D:\'), isNull);
      expect(BankIo.parentOf('D:/'), isNull);
      expect(BankIo.parentOf('题库'), isNull);
    });
  });

  group('BankIo.parentOf SAF', () {
    String treeUri(String docId) =>
        'content://com.android.externalstorage.documents/tree/'
        '${Uri.encodeComponent(docId)}';

    test('多级 tree id 取上一层', () {
      final ({String key, String label})? parent = BankIo.parentOf(
        treeUri('primary:tbankQuestion/大学物理-震动、波动和声'),
      );
      expect(parent, isNotNull);
      expect(parent!.label, 'tbankQuestion');
      expect(parent.key, 'saf:primary/tbankQuestion');
    });

    test('授权的是卷根时用卷名做父级', () {
      final ({String key, String label})? parent = BankIo.parentOf(
        treeUri('primary:'),
      );
      expect(parent, isNotNull);
      expect(parent!.label, 'primary');
      expect(parent.key, 'saf:primary');
    });

    test('不是 tree 结构的 content URI 返回 null', () {
      expect(BankIo.parentOf('content://media/external/images/1'), isNull);
    });
  });

  group('分组键', () {
    test('同一父目录下的不同子目录得到相同 key', () {
      final String? a = BankIo.parentOf(
        r'D:\TR\tbank\tbankQuestion\大学物理-震动、波动和声',
      )?.key;
      final String? b = BankIo.parentOf(r'D:\TR\tbank\tbankQuestion\组织学')?.key;
      expect(a, isNotNull);
      expect(a, b);
    });

    test('不同父目录得到不同 key', () {
      final String? a = BankIo.parentOf(r'D:\TR\tbank\tbankQuestion\组织学')?.key;
      final String? b = BankIo.parentOf(r'D:\harness\study_work\细胞生物学题库')?.key;
      expect(a, isNot(b));
    });
  });
}
