import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
  bool _landscapeNavVisible = false; // 横屏底部导航是否临时展开
  Orientation? _lastOrientation;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final Orientation orientation = MediaQuery.orientationOf(context);
    if (orientation == _lastOrientation) return;
    _lastOrientation = orientation;
    if (orientation == Orientation.landscape) {
      // 横屏只隐藏顶部状态栏，保留系统底部导航栏。
      SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.manual,
        overlays: <SystemUiOverlay>[SystemUiOverlay.bottom],
      );
    } else {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  /// 题库管理页点了某个题库：保存选择并切到练习页。
  void _openBank(QuestionBankFile bank) {
    setState(() {
      _selectedBank = bank;
      _currentIndex = _practiceTabIndex;
    });
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

    final NavigationBar navigationBar = NavigationBar(
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
    );

    return Scaffold(
      body: Stack(
        children: <Widget>[
          IndexedStack(index: _currentIndex, children: pages),
          // 横屏默认收起底部导航；左下角小图标只负责把原导航
          // 呼出/收回，不再另造一层菜单。
          if (isLandscape)
            Positioned(
              left: 8,
              bottom: 8,
              child: SafeArea(
                child: FloatingActionButton.small(
                  heroTag: 'landscape-menu-toggle',
                  tooltip: _landscapeNavVisible ? '隐藏底部导航' : '显示底部导航',
                  onPressed: () => setState(
                    () => _landscapeNavVisible = !_landscapeNavVisible,
                  ),
                  child: Icon(
                    _landscapeNavVisible
                        ? Icons.keyboard_arrow_down
                        : Icons.menu,
                  ),
                ),
              ),
            ),
        ],
      ),
      // 横屏默认隐藏底部导航，点左下角图标后恢复原来的 NavigationBar。
      bottomNavigationBar: isLandscape
          ? (_landscapeNavVisible ? navigationBar : null)
          : navigationBar,
    );
  }
}
