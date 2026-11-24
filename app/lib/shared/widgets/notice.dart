import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// What a [NoticeBanner] is telling the user, which sets its colour and icon.
enum NoticeTone { info, warning, error, success }

/// A tinted, rounded strip with an icon, a message and an optional action: the one style for
/// notes, warnings and errors inside cards (loading problems, fallbacks, stale data).
class NoticeBanner extends StatelessWidget {
  const NoticeBanner({
    super.key,
    required this.message,
    this.tone = NoticeTone.info,
    this.icon,
    this.actionLabel,
    this.onAction,
    this.title,
  });

  final String message;
  final NoticeTone tone;
  final IconData? icon;
  final String? title;

  /// A text button at the end; hidden when [onAction] is null.
  final String? actionLabel;
  final VoidCallback? onAction;

  static Color colorFor(BuildContext context, NoticeTone tone) => switch (tone) {
    NoticeTone.info => TactileTokens.of(context).primary,
    NoticeTone.warning => StatusColors.of(context).uncertain,
    NoticeTone.error => Theme.of(context).colorScheme.error,
    NoticeTone.success => StatusColors.of(context).inCall,
  };

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final text = Theme.of(context).textTheme;
    final c = colorFor(context, tone);
    final glyph =
        icon ??
        switch (tone) {
          NoticeTone.info => Icons.info_outline_rounded,
          NoticeTone.warning => Icons.warning_amber_rounded,
          NoticeTone.error => Icons.error_outline_rounded,
          NoticeTone.success => Icons.check_circle_outline_rounded,
        };
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (title != null)
          Text(
            title!,
            style: text.titleSmall?.copyWith(color: p.ink, fontWeight: FontWeight.w600),
          ),
        Text(
          message,
          style: text.bodyMedium?.copyWith(color: tone == NoticeTone.error ? c : p.text2),
        ),
      ],
    );
    return Semantics(
      container: true,
      liveRegion: tone == NoticeTone.error,
      child: Container(
        padding: const EdgeInsets.fromLTRB(Spacing.md, Spacing.sm + 2, Spacing.sm, Spacing.sm + 2),
        decoration: BoxDecoration(
          color: c.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(Radii.md),
          border: Border.all(color: c.withValues(alpha: 0.35)),
        ),
        child: LayoutBuilder(
          builder: (context, box) {
            final action = onAction == null || actionLabel == null
                ? null
                : TextButton(
                    onPressed: onAction,
                    style: TextButton.styleFrom(foregroundColor: c),
                    child: Text(actionLabel!),
                  );
            final row = Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(glyph, size: 20, color: c),
                ),
                const SizedBox(width: Spacing.sm + 2),
                Expanded(child: body),
                if (action != null && box.maxWidth >= 360) ...[
                  const SizedBox(width: Spacing.sm),
                  action,
                ],
              ],
            );
            if (action == null || box.maxWidth >= 360) return row;
            // Narrow: the action goes under the message rather than squeezing it.
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                row,
                Align(alignment: AlignmentDirectional.centerEnd, child: action),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Formats [seconds] as `mm:ss` (the AI Coach's moment style).
String formatMinSec(num seconds) =>
    '${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds.floor() % 60).toString().padLeft(2, '0')}';

/// A small pill that plays the video from a moment: a play glyph and the time. Used for every
/// "jump to this moment" link, so they all look and behave the same.
class TimePill extends StatelessWidget {
  const TimePill({super.key, required this.label, required this.onTap, this.tooltip});

  final String label;
  final VoidCallback? onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final t = TactileTokens.of(context);
    final p = AppPalette.of(context);
    Widget pill = Material(
      color: t.primary.withValues(alpha: 0.12),
      shape: StadiumBorder(side: BorderSide(color: t.primary.withValues(alpha: 0.35))),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: ConstrainedBox(
          // A comfortable tap height without looking like a big button.
          constraints: const BoxConstraints(minHeight: 34),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 12, 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.play_arrow_rounded, size: 18, color: t.primary),
                const SizedBox(width: 2),
                Text(
                  label,
                  style: kFigureStyle.copyWith(
                    fontSize: 13.5,
                    color: p.ink,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    pill = Semantics(button: true, label: 'Play from $label', excludeSemantics: true, child: pill);
    return Tooltip(message: tooltip ?? 'Play from $label', child: pill);
  }
}
