import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:tbank/models/question_bank_file.dart';
import 'package:tbank/services/bank_io.dart';
import 'package:tbank/services/bank_repository.dart';

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.root);

  final String root;

  @override
  Future<String?> getApplicationSupportPath() async => root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('tbank_stats_test_');
    PathProviderPlatform.instance = _FakePathProvider(temp.path);
    BankRepository.resetForTest();
  });

  tearDown(() async {
    BankRepository.resetForTest();
    try {
      if (await temp.exists()) await temp.delete(recursive: true);
    } on FileSystemException {
      // Windows 句柄延迟释放。
    }
  });

  test('统计解析在后台 isolate 完成，并返回错题排行', () async {
    final File bank = File('${temp.path}${Platform.pathSeparator}bank.json');
    await bank.writeAsString(
      jsonEncode(<String, dynamic>{
        'questions': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'Q1',
            'type': 'single_choice',
            'question': '第一题',
            'options': <Map<String, String>>[
              <String, String>{'key': 'A', 'text': '甲'},
              <String, String>{'key': 'B', 'text': '乙'},
            ],
            'correctAnswer': <String>['A'],
            'stats': <String, int>{'attemptCount': 5, 'wrongCount': 3},
          },
          <String, dynamic>{
            'id': 'Q2',
            'type': 'single_choice',
            'question': '第二题',
            'options': <Map<String, String>>[
              <String, String>{'key': 'A', 'text': '甲'},
              <String, String>{'key': 'B', 'text': '乙'},
            ],
            'correctAnswer': <String>['A'],
            'stats': <String, int>{'attemptCount': 4, 'wrongCount': 1},
          },
        ],
      }),
    );

    final List<QuestionBankFile> files = await BankIo.listJsonFiles(temp.path);
    final Map<String, BankStat> stats = await BankRepository.instance
        .loadStats(files);

    final BankStat stat = stats[bank.path]!;
    expect(stat.questionCount, 2);
    expect(stat.attemptCount, 9);
    expect(stat.wrongCount, 4);
    expect(stat.practiceCount, 4);
    expect(stat.wrongItems.first.question, '第一题');
    expect(stat.wrongItems.first.wrong, 3);
  });
}
