import 'package:flutter/material.dart';

import 'ai_generate_page.dart';
import 'book_ai_generate_page.dart';
import 'mistake_books_page.dart';
import 'quick_start_page.dart';
import 'settings_page.dart';
import 'stats_page.dart';

/// 个人中心。
///
/// 提供「快速开始」「学习统计」「错题本」「AI 出题」「拍书出题」「设置」
/// 六个入口。
class MePage extends StatelessWidget {
  const MePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('我的')),
      body: ListView(
        // 四周留出边距，按钮不贴边
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
        children: <Widget>[
          // 快速开始：六步上手说明，内容来自 assets/texts/quick_start.md
          SizedBox(
            width: double.infinity,
            child: FilledButton.tonalIcon(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const QuickStartPage(),
                  ),
                );
              },
              icon: const Icon(Icons.rocket_launch_outlined, size: 20),
              label: const Text('快速开始'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),

          // 学习统计：汇总所有题库的作答次数、正确率、错得最多的题
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const StatsPage()),
                );
              },
              icon: const Icon(Icons.bar_chart_outlined, size: 20),
              label: const Text('学习统计'),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),

          // 错题本：收集所有题库里答错过的题，按本练习
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const MistakeBooksPage(),
                  ),
                );
              },
              icon: const Icon(Icons.menu_book_outlined, size: 20),
              label: const Text('错题本'),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),

          // AI 出题：按主题和要求生成练习题，保存到 App 私有目录的 Question/
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const AiGeneratePage(),
                  ),
                );
              },
              icon: const Icon(Icons.auto_awesome_outlined, size: 20),
              label: const Text('AI 出题'),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),

          // 拍书出题：拍教材题目 / 知识点，AI 识别后出题，可自定义保存位置
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const BookAiGeneratePage(),
                  ),
                );
              },
              icon: const Icon(Icons.photo_camera_outlined, size: 20),
              label: const Text('拍书出题'),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),

          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const SettingsPage()),
                );
              },
              icon: const Icon(Icons.settings_outlined, size: 20),
              label: const Text('设置'),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
