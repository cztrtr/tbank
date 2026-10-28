import 'package:flutter/material.dart';

import 'mistake_books_page.dart';
import 'settings_page.dart';

/// 个人中心。
///
/// 目前有「错题本」和「设置」两个入口，其余内容后续再补。
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

          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const SettingsPage(),
                  ),
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
