import 'package:flutter/material.dart';

import '../../data/models/coach.dart';

/// The knowledge-base chunks a coach answer cited (D42). Shown, not tappable: the knowledge
/// base lives on the server.
class SourceChips extends StatelessWidget {
  const SourceChips({super.key, required this.sources});

  final List<CoachSource> sources;

  /// "Footwork, base position and split step: Split step" -> "Split step".
  static String shortTitle(CoachSource s) => s.title.split(': ').last;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Sources',
    child: Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [
        for (final s in sources)
          Tooltip(
            message: s.title,
            child: Chip(
              avatar: const Icon(Icons.menu_book_outlined, size: 16),
              label: Text(shortTitle(s)),
              visualDensity: VisualDensity.compact,
            ),
          ),
      ],
    ),
  );
}
