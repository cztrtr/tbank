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

  static const List<({IconData icon, IconData selectedIcon, String label})>
  _destinations = <({IconData icon, IconData selectedIcon, String label})>[
    (
      icon: Icons.home_outlined,
      selectedIcon: Icons.home,
      label: '首页',
    ),
    (
      icon: Icons.collections_bookmark_outlined,
      selectedIcon: Icons.collections_bookmark,
      label: '管理',
    ),
    (
      icon: Icons.quiz_outlined,
      selectedIcon: Icons.quiz,
      label: '练习',
    ),
    (
      icon: Icons.person_outline,
      selectedIcon: Icons.person,
      label: '我的',
    ),
  ];

  int _currentIndex = 0; // 当前底部导航下标
  QuestionBankFile? _selectedBank; // 当前选中的题库，null 表示还没选

  /// 题库管理页点了某个题库：保存选择并切到练习页。
  void _openBank(QuestionBankFile bank) {
    setState(() {
      _selectedBank = bank;
      _currentIndex = _practiceTabIndex;
    });
  }

  Future<void> _showLandscapeMenu() async {
    final int? selected = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const ListTile(
                title: Text('页面菜单'),
                subtitle: Text('横屏时底部导航会收起，用这里切换页面。'),
              ),
              for (int i = 0; i < _destinations.length; i++)
                ListTile(
                  leading: Icon(
                    i == _currentIndex
                        ? _destinations[i].selectedIcon
                        : _destinations[i].icon,
                  ),
                  title: Text(_destinations[i].label),
                  selected: i == _currentIndex,
                  onTap: () => Navigator.of(sheetContext).pop(i),
                ),
            ],
          ),
        );
      },
    );
    if (!mounted || selected == null) return;
    setState(() => _currentIndex = selected);
  }

  @override
  Widget build(BuildContext context) {
    final bool isLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;

    // 每次重建都把最新的选中题库传给 PracticePage，
    // 这样题库页 emit 新选择后，练习页能通过 didUpdateWidget 感知。
    // 页面实例在这里重新创建，但 IndexedStack 会按位置复用各自的 State。
    final pages = <Widget>[
      const HomePage(),
      QuestionBankPage(onOpenBank: _openBank),
      PracticePage(bank: _selectedBank),
      const MePage(),
    ];

    return Scaffold(
      body: Stack(
        children: <Widget>[
          IndexedStack(index: _currentIndex, children: pages),
          // 横屏隐藏底部导航后，左下角留一个菜单入口，避免平板用户
          // 找不到切换页面的地方。
          if (isLandscape)
            Positioned(
              left: 12,
              bottom: 12,
              child: SafeArea(
                child: FloatingActionButton.extended(
                  heroTag: 'landscape-menu',
                  onPressed: _showLandscapeMenu,
                  icon: const Icon(Icons.menu),
                  label: const Text('菜单'),
                ),
              ),
            ),
        ],
      ),
      // 横屏时优先把高度留给练习/手写区，不显示底部导航。
      bottomNavigationBar: isLandscape
          ? null
          : NavigationBar(
              selectedIndex: _currentIndex,
              onDestinationSelected: (index) =>
                  setState(() => _currentIndex = index),
              destinations: <NavigationDestination>[
                for (final destination in _destinations)
                  NavigationDestination(
                    icon: Icon(destination.icon),
                    selectedIcon: Icon(destination.selectedIcon),
                    label: destination.label,
                  ),
              ],
            ),
    );
  }
}
