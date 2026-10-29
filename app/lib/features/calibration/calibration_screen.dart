import 'package:flutter/material.dart';

import '../../shared/widgets/message_view.dart';

class CalibrationScreen extends StatelessWidget {
  const CalibrationScreen({super.key, required this.videoId});

  final String videoId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Court calibration')),
      body: const MessageView(
        icon: Icons.construction,
        message: 'Court calibration',
        detail: 'Coming in T5.1 (docs/PHASES.md)',
      ),
    );
  }
}
