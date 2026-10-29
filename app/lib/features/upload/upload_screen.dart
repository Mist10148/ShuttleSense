import 'package:flutter/material.dart';

import '../../shared/widgets/message_view.dart';

class UploadScreen extends StatelessWidget {
  const UploadScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('New analysis')),
      body: const MessageView(
        icon: Icons.construction,
        message: 'New analysis',
        detail: 'Coming in T4.2 (docs/PHASES.md)',
      ),
    );
  }
}
