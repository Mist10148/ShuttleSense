import 'package:flutter/material.dart';

import 'package:url_launcher/url_launcher.dart';

import '../../data/models/coach.dart';

/// Inspect the retrieved passage and its reference without leaving the chat.
class SourceChips extends StatelessWidget {
  const SourceChips({super.key, required this.sources});

  final List<CoachSource> sources;

  /// "Footwork, base position and split step: Split step" -> "Split step".
  static String shortTitle(CoachSource s) => s.title.split(': ').last;

  void _inspect(BuildContext context, CoachSource source) {
    final url = Uri.tryParse(source.url ?? '');
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(source.title),
        content: SingleChildScrollView(
          child: SelectableText(
            [
              if (source.excerpt != null) source.excerpt!,
              if (source.reference != null) source.reference!,
              if (source.edition != null) source.edition!,
              if (source.excerpt == null && source.reference == null) source.id,
            ].join('\n\n'),
          ),
        ),
        actions: [
          if (url != null && url.scheme == 'https' && url.host.isNotEmpty)
            TextButton(
              onPressed: () async {
                if (!await launchUrl(url) && context.mounted) {
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('Could not open reference.')));
                }
              },
              child: const Text('Open reference'),
            ),
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
        ],
      ),
    );
  }

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
            child: ActionChip(
              onPressed: () => _inspect(context, s),
              avatar: const Icon(Icons.menu_book_outlined, size: 16),
              label: Text(shortTitle(s)),
              visualDensity: VisualDensity.compact,
            ),
          ),
      ],
    ),
  );
}
