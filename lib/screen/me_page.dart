import 'package:flutter/material.dart';

import 'settings_page.dart';

/// 个人中心。
///
/// 目前只有「设置」一个入口，其余内容后续再补。
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
