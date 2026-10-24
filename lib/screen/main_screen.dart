import 'package:flutter/material.dart';

import '../models/question_bank_file.dart';
import 'home_page.dart';
import 'me_page.dart';
import 'practice_page.dart';
import 'question_bank_page.dart';

/// 应用主框架：底部导航栏 + 四个页面。
///
/// 页面用 IndexedStack 承载，切 tab 不会销毁页面 State，
/// 因此题库页的扫描结果、练习页的作答进度都会被保留。
class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  static const int _practiceTabIndex = 2; // 练习在底部导航里的位置

  int _currentIndex = 0; // 当前底部导航下标
  QuestionBankFile? _selectedBank; // 当前选中的题库，null 表示还没选

  /// 题库管理页点了某个题库：保存选择并切到练习页。
  void _openBank(QuestionBankFile bank) {
    setState(() {
      _selectedBank = bank;
      _currentIndex = _practiceTabIndex;
    });
  }

  @override
  Widget build(BuildContext context) {
    // 每次重建都把最新的选中题库传给 PracticePage，
    // 这样题库页 emit 新选择后，练习页能通过 didUpdateWidget 感知。
    final pages = <Widget>[
      const HomePage(),
      QuestionBankPage(onOpenBank: _openBank),
      PracticePage(bank: _selectedBank),
      const MePage(),
    ];

    return Scaffold(
      body: IndexedStack(index: _currentIndex, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (index) =>
            setState(() => _currentIndex = index),
        destinations: const <NavigationDestination>[
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: '首页',
          ),
          NavigationDestination(
            icon: Icon(Icons.collections_bookmark_outlined),
            selectedIcon: Icon(Icons.collections_bookmark),
            label: '管理',
          ),
          NavigationDestination(
            icon: Icon(Icons.quiz_outlined),
            selectedIcon: Icon(Icons.quiz),
            label: '练习',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: '我的',
          ),
        ],
      ),
    );
  }
}