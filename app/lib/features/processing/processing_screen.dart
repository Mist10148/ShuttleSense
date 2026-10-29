import 'package:flutter/material.dart';

import '../../shared/widgets/message_view.dart';

class ProcessingScreen extends StatelessWidget {
  const ProcessingScreen({super.key, required this.jobId});

  final String jobId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Processing')),
      body: const MessageView(
        icon: Icons.construction,
        message: 'Processing',
        detail: 'Coming in T4.4 (docs/PHASES.md)',
      ),
    );
  }
}
