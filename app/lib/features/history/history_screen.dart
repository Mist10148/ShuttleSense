import 'package:flutter/material.dart';

import '../../shared/widgets/message_view.dart';

class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('History')),
      body: const MessageView(
        icon: Icons.construction,
        message: 'History',
        detail: 'Coming in T4.8 (docs/PHASES.md)',
      ),
    );
  }
}
