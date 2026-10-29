import 'package:flutter/material.dart';

import '../../shared/widgets/message_view.dart';

class ConnectScreen extends StatelessWidget {
  const ConnectScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Connect to server')),
      body: const MessageView(
        icon: Icons.construction,
        message: 'Connect to server',
        detail: 'Coming in T4.1 (docs/PHASES.md)',
      ),
    );
  }
}
