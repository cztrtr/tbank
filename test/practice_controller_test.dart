import 'package:flutter_test/flutter_test.dart';
import 'package:tbank/models/question_bank.dart';
import 'package:tbank/screen/practice_controller.dart';
import 'package:tbank/services/practice_progress.dart';

Question _question(String id) => Question(
      id: id,
      type: QuestionType.singleChoice,
      question: id,
      options: const <QuestionOption>[
        QuestionOption(key: 'A', text: 'A'),
        QuestionOption(key: 'B', text: 'B'),
      ],
      correctAnswers: const <String>['A'],
      stats: QuestionStats(),
    );

PracticeController _controller() => PracticeController(
      bank: QuestionBank(
        questions: <Question>[_question('q_1'), _question('q_2')],
      ),
    );

void main() {
  test('record 记录计数与选择，重复提交不再计数', () {
    final controller = _controller();
    controller.selected.add('A');

    expect(controller.record(true), isTrue);
    expect(controller.answered, isTrue);
    expect(controller.wasCorrect, isTrue);
    expect(controller.answeredCount, 1);
    expect(controller.correctCount, 1);
    expect(controller.answeredStates[0]?.selected, <String>{'A'});

    // 同一题再提交：返回 false，计数不变
    expect(controller.record(false), isFalse);
    expect(controller.answeredCount, 1);
    expect(controller.correctCount, 1);
  });

  test('goTo 恢复已答题的判分结果，未答题保持空白', () {
    final controller = _controller();
    controller.selected.add('B');
    controller.record(false);

    controller.goTo(1);
    expect(controller.index, 1);
    expect(controller.answered, isFalse);
    expect(controller.selected, isEmpty);

    controller.goTo(0);
    expect(controller.index, 0);
    expect(controller.answered, isTrue);
    expect(controller.wasCorrect, isFalse);
    expect(controller.selected, <String>{'B'});
  });

  test('restart 清空本次计数与已答状态', () {
    final controller = _controller();
    controller.selected.add('A');
    controller.record(true);
    controller.goTo(1);

    controller.restart();
    expect(controller.index, 0);
    expect(controller.answeredCount, 0);
    expect(controller.correctCount, 0);
    expect(controller.answeredStates, isEmpty);
    expect(controller.answered, isFalse);
  });

  test('loadBank 按断点恢复题号、计数和已答结果', () {
    final controller = _controller();
    final PracticeProgress progress = PracticeProgress(
      index: 1,
      answeredCount: 1,
      correctCount: 1,
      answers: <int, ({bool correct, Set<String> selected})>{
        0: (correct: true, selected: <String>{'A'}),
      },
      questionIds: <String>['q_1', 'q_2'],
    );

    controller.loadBank(
      QuestionBank(
        questions: <Question>[_question('q_1'), _question('q_2')],
      ),
      progress,
    );

    expect(controller.index, 1);
    expect(controller.answeredCount, 1);
    expect(controller.correctCount, 1);
    expect(controller.answered, isFalse);

    controller.goTo(0);
    expect(controller.answered, isTrue);
    expect(controller.selected, <String>{'A'});
  });
}
