import '../models/question_bank.dart';
import '../services/practice_progress.dart';

/// 练习页的答题状态机。
///
/// 只保存「本次练习」的状态：题目列表、当前题号、选中项、已答结果和计数；
/// 题库文件的读写、AI 调用、界面刷新仍由 PracticePage 负责。
/// 抽出来以后页面只做渲染，状态迁移可以单独写测试。
class PracticeController {
  PracticeController({QuestionBank? bank})
      : _bank = bank ?? QuestionBank(questions: <Question>[]);

  QuestionBank _bank;

  /// 当前题库；加载完成前是空题库。
  QuestionBank get bank => _bank;

  /// 当前第几题（从 0 开始）。
  int index = 0;

  /// 选择题当前选中了哪些选项。
  final Set<String> selected = <String>{};

  /// 本次练习已作答的题目：下标 → (是否答对, 当时的选择)。
  final Map<int, ({bool correct, Set<String> selected})> answeredStates =
      <int, ({bool correct, Set<String> selected})>{};

  /// 当前题是否已经判定过。
  bool answered = false;

  /// 当前题答得对不对。
  bool wasCorrect = false;

  /// 本次练习一共答了多少题。
  int answeredCount = 0;

  /// 本次练习答对了多少题。
  int correctCount = 0;

  /// 整套题是否做完。
  bool finished = false;

  /// 当前题目；题库为空时调用方不应访问。
  Question get current => _bank.questions[index];

  /// 当前是不是最后一题。
  bool get isLast => index + 1 >= _bank.questions.length;

  /// 换一份题库，并按断点恢复（没有断点时从头开始）。
  void loadBank(QuestionBank bank, PracticeProgress? progress) {
    _bank = bank;
    index = 0;
    selected.clear();
    answeredStates.clear();
    answered = false;
    wasCorrect = false;
    answeredCount = 0;
    correctCount = 0;
    finished = false;

    if (progress == null) return;

    index = progress.index;
    answeredCount = progress.answeredCount;
    correctCount = progress.correctCount;
    answeredStates.addAll(progress.answers);

    final ({bool correct, Set<String> selected})? saved =
        answeredStates[index];
    if (saved != null) {
      answered = true;
      wasCorrect = saved.correct;
      selected.addAll(saved.selected);
    }
  }

  /// 记录一次作答；已经答过返回 false（由调用方跳过重复计数）。
  bool record(bool correct) {
    if (answered) return false;

    answered = true;
    wasCorrect = correct;
    answeredCount += 1;
    if (correct) correctCount += 1;
    answeredStates[index] = (
      correct: correct,
      selected: Set<String>.of(selected),
    );
    return true;
  }

  /// 跳到指定题；这题答过就恢复当时的判分结果和选择。
  void goTo(int nextIndex) {
    index = nextIndex;
    selected.clear();
    answered = false;
    wasCorrect = false;

    final ({bool correct, Set<String> selected})? saved =
        answeredStates[nextIndex];
    if (saved == null) return;

    answered = true;
    wasCorrect = saved.correct;
    selected.addAll(saved.selected);
  }

  /// 重新从第一题开始；题目统计是累计值，不重置。
  void restart() {
    index = 0;
    selected.clear();
    answeredStates.clear();
    answered = false;
    wasCorrect = false;
    answeredCount = 0;
    correctCount = 0;
    finished = false;
  }
}
