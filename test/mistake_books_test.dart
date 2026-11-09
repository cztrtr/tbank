import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:tbank/services/app_config.dart';
import 'package:tbank/services/mistake_books.dart';

/// 把 App 私有目录固定到临时文件夹，方便在桌面测试。
class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.root);

  final String root;

  @override
  Future<String?> getApplicationSupportPath() async => root;

  @override
  Future<String?> getApplicationDocumentsPath() async => '$root/docs';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late Directory mistakes;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('tbank_mistake_test_');
    PathProviderPlatform.instance = _FakePathProvider(temp.path);
    mistakes = Directory('${temp.path}${Platform.pathSeparator}mistakes');
    await mistakes.create(recursive: true);
    AppConfig.questionBankDirsNotifier.value = const <String>[];
    MistakeBooks.resetStartupMigrationForTest();
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('分组名带斜杠时，工作副本名不能包含路径分隔符', () {
    const MistakeBookInfo info = MistakeBookInfo(
      name: '流体力学-Alpha',
      path: r'/data/mistakes/#tbankQuestion/医用物理学/流体力学-Alpha.json',
      groupName: '#tbankQuestion/医用物理学',
      total: 1,
      completed: 0,
    );

    final String name = info.toBankFile('/data/mistakes/x').name;

    expect(name, isNot(contains('/')));
    expect(name, isNot(contains(r'\')));
    expect(name, contains('流体力学-Alpha'));
    expect(name.endsWith('.json'), isTrue);
  });

  test('删除分组里的错题本时，删除清单写到 mistakes 根目录', () async {
    final Directory group = Directory(
      '${mistakes.path}${Platform.pathSeparator}a${Platform.pathSeparator}b',
    );
    await group.create(recursive: true);

    final File bookFile = File(
      '${group.path}${Platform.pathSeparator}Alpha.json',
    );
    await bookFile.writeAsString(
      jsonEncode(<String, dynamic>{
        'questions': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'C001',
            'origin': 'q_stable_id',
            'mistakeScore': 3,
          },
        ],
      }),
    );

    await MistakeBooks.deleteBook(
      MistakeBookInfo(
        name: 'Alpha',
        path: bookFile.path,
        groupName: 'a/b',
        total: 1,
        completed: 0,
      ),
    );

    expect(await bookFile.exists(), isFalse, reason: '本子文件应被删除');

    final File deletedList = File(
      '${mistakes.path}${Platform.pathSeparator}deleted_origins.json',
    );
    expect(await deletedList.exists(), isTrue, reason: '清单应写在根目录');

    final List<dynamic> decoded =
        jsonDecode(await deletedList.readAsString()) as List<dynamic>;
    expect(decoded, contains('q_stable_id'));
  });

  test('旧的子目录清单会被迁移到根目录，并删除残留文件', () async {
    final Directory group = Directory(
      '${mistakes.path}${Platform.pathSeparator}a',
    );
    await group.create(recursive: true);
    final File legacy = File(
      '${group.path}${Platform.pathSeparator}deleted_origins.json',
    );
    await legacy.writeAsString(jsonEncode(<String>['q_old']));

    final File bookFile = File(
      '${group.path}${Platform.pathSeparator}Beta.json',
    );
    await bookFile.writeAsString(
      jsonEncode(<String, dynamic>{
        'questions': <Map<String, dynamic>>[
          <String, dynamic>{'id': 'C001', 'origin': 'q_new', 'mistakeScore': 3},
        ],
      }),
    );

    await MistakeBooks.deleteBook(
      MistakeBookInfo(
        name: 'Beta',
        path: bookFile.path,
        groupName: 'a',
        total: 1,
        completed: 0,
      ),
    );

    expect(await legacy.exists(), isFalse, reason: '旧的子目录清单应被清理');

    final File deletedList = File(
      '${mistakes.path}${Platform.pathSeparator}deleted_origins.json',
    );
    final List<dynamic> decoded =
        jsonDecode(await deletedList.readAsString()) as List<dynamic>;
    expect(decoded, containsAll(<String>['q_old', 'q_new']));
  });

  test('启动迁移只跑一次，并写一次性标记', () async {
    final Directory bankDir = Directory(
      '${temp.path}${Platform.pathSeparator}启动题库',
    );
    await bankDir.create(recursive: true);
    final File bankFile = File(
      '${bankDir.path}${Platform.pathSeparator}题库.json',
    );
    await bankFile.writeAsString(
      jsonEncode(<String, dynamic>{
        'questions': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'Q001',
            'type': 'fill_blank',
            'question': '题',
          },
        ],
      }),
    );

    AppConfig.questionBankDirsNotifier.value = <String>[bankDir.path];
    MistakeBooks.resetStartupMigrationForTest();

    await MistakeBooks.migrateAllBankIds();

    final Map<String, dynamic> decoded =
        jsonDecode(await bankFile.readAsString()) as Map<String, dynamic>;
    final List<dynamic> questions = decoded['questions'] as List<dynamic>;
    final String id =
        (questions.single as Map<String, dynamic>)['id'] as String;
    expect(id.startsWith('q_'), isTrue, reason: '旧 id 应被替换成稳定随机 id');

    final File marker = File(
      '${temp.path}${Platform.pathSeparator}id_migration_v1.done',
    );
    expect(await marker.exists(), isTrue);

    // 模拟第二次启动：标记存在，不再读/写题库文件
    final String before = await bankFile.readAsString();
    MistakeBooks.resetStartupMigrationForTest();
    await MistakeBooks.migrateAllBankIds();
    expect(await bankFile.readAsString(), before);
  });

  test('子目录题库的错题按「根目录/子目录」分组', () async {
    final Directory root = Directory('${temp.path}${Platform.pathSeparator}高数');
    final Directory sub = Directory('${root.path}${Platform.pathSeparator}线代');
    await sub.create(recursive: true);

    final File bankFile = File('${sub.path}${Platform.pathSeparator}第一章.json');
    await bankFile.writeAsString(
      jsonEncode(<String, dynamic>{
        'questions': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'Q001',
            'type': 'fill_blank',
            'question': '题',
            'options': <dynamic>[],
            'correctAnswer': <String>['答案'],
            'stats': <String, int>{'attemptCount': 1, 'wrongCount': 1},
          },
        ],
      }),
    );

    AppConfig.questionBankDirsNotifier.value = <String>[root.path];
    final int added = await MistakeBooks.collectFromBanks();
    expect(added, 1);

    final List<MistakeBookInfo> books = await MistakeBooks.list();
    expect(books, hasLength(1));
    expect(books.single.groupName, '高数/线代');
    expect(
      books.single.path.replaceAll(r'\', '/'),
      contains('mistakes/高数/线代/Alpha.json'),
    );
  });

  test('同一分组下不同插件的错题分本，一本只属于一个插件', () async {
    final Directory root = Directory(
      '${temp.path}${Platform.pathSeparator}混合组',
    );
    await root.create(recursive: true);

    Future<void> writeBank(String name, {String? plugin}) async {
      final Map<String, dynamic> json = <String, dynamic>{
        'questions': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'Q_$name',
            'type': 'fill_blank',
            'question': '题',
            'options': <dynamic>[],
            'correctAnswer': <String>['答案'],
            'stats': <String, int>{'attemptCount': 1, 'wrongCount': 1},
          },
        ],
      };
      if (plugin != null) json['plugin'] = plugin;

      await File('${root.path}${Platform.pathSeparator}$name.json')
          .writeAsString(jsonEncode(json));
    }

    await writeBank('内置');
    await writeBank('编程', plugin: 'coding');

    AppConfig.questionBankDirsNotifier.value = <String>[root.path];
    final int added = await MistakeBooks.collectFromBanks();
    expect(added, 2);

    final List<MistakeBookInfo> books = await MistakeBooks.list();
    expect(books, hasLength(2));
    expect(books.map((MistakeBookInfo book) => book.plugin).toSet(), <String>{
      'standard',
      'coding',
    });
    expect(
      books.every((MistakeBookInfo book) => book.groupName == '混合组'),
      isTrue,
    );
    expect(books.map((MistakeBookInfo book) => book.name).toSet(), <String>{
      'Alpha',
      'Beta',
    });
  });
}
