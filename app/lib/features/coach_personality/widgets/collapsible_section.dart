import 'package:flutter/material.dart';

import '../../../shared/widgets/section_card.dart';

/// A card on the personality page that opens and closes, so the page starts short and the
/// detail is one tap away (docs/coach-personality/ui-ux.md, progressive disclosure).
class CollapsibleSection extends StatefulWidget {
  const CollapsibleSection({
    super.key,
    required this.title,
    required this.icon,
    required this.child,
    this.initiallyOpen = false,
    this.badge,
  });

  final String title;
  final IconData icon;
  final Widget child;
  final bool initiallyOpen;

  /// A short note next to the toggle, such as "2 changes".
  final String? badge;

  @override
  State<CollapsibleSection> createState() => _CollapsibleSectionState();
}

class _CollapsibleSectionState extends State<CollapsibleSection> {
  late bool _open = widget.initiallyOpen;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return SectionCard(
      title: widget.title,
      icon: widget.icon,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.badge != null)
            Text(
              widget.badge!,
              style: text.labelMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          IconButton(
            tooltip: _open ? 'Hide ${widget.title}' : 'Show ${widget.title}',
            icon: Icon(_open ? Icons.expand_less : Icons.expand_more),
            onPressed: () => setState(() => _open = !_open),
          ),
        ],
      ),
      child: AnimatedSize(
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 180),
        alignment: Alignment.topCenter,
        child: _open ? widget.child : const SizedBox(width: double.infinity),
      ),
    );
  }
}
