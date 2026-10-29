import 'package:flutter/material.dart';

import '../../shared/widgets/message_view.dart';

class ResultsScreen extends StatelessWidget {
  const ResultsScreen({super.key, required this.jobId});

  final String jobId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Results')),
      body: const MessageView(
        icon: Icons.construction,
        message: 'Results',
        detail: 'Coming in T4.5 (docs/PHASES.md)',
      ),
    );
  }
}
