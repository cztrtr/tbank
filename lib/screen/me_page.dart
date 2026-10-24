import 'package:flutter/material.dart';

import '../widgets/page_placeholder.dart';

/// 个人中心。
class MePage extends StatelessWidget {
  const MePage({super.key});

  @override
  Widget build(BuildContext context) {
    return const PagePlaceholder(title: 'ME', icon: Icons.person_outline);
  }
}
