import 'package:flutter/material.dart';

import '../../core/responsive/breakpoints.dart';
import '../../core/theme/app_theme.dart';
import '../../shared/widgets/data_display.dart';
import '../../shared/widgets/dependent_switch.dart';
import '../../shared/widgets/helper_text.dart';
import '../../shared/widgets/message_view.dart';
import '../../shared/widgets/status_pill.dart';
import '../../shared/widgets/step_indicator.dart';
import '../../shared/widgets/surfaces.dart';

/// Every design token and shared component on one page, in light or dark (/styleguide).
/// Reachable without a server so the look can be reviewed on any machine.
class StyleguideScreen extends StatefulWidget {
  const StyleguideScreen({super.key});

  @override
  State<StyleguideScreen> createState() => _StyleguideScreenState();
}

class _StyleguideScreenState extends State<StyleguideScreen> {
  Brightness? _brightness;
  bool _calibrate = true;
  String _match = 'singles';
  final _overlays = {'Trail', 'Speed'};

  @override
  Widget build(BuildContext context) {
    final brightness = _brightness ?? Theme.of(context).brightness;
    final theme = brightness == Brightness.dark ? AppTheme.dark() : AppTheme.light();
    final gutter = Breakpoints.gutter(Breakpoints.of(context));
    return Theme(
      data: theme,
      child: Scaffold(
        body: AppBackground(
          child: SafeArea(
            child: ListView(
              padding: EdgeInsets.all(gutter),
              children: [
                MaxWidth(
                  maxWidth: 1200,
                  child: GlassPanel(
                    padding: EdgeInsets.all(gutter),
                    child: Builder(builder: (context) => _content(context, brightness)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _content(BuildContext context, Brightness brightness) {
    final text = Theme.of(context).textTheme;
    final p = AppPalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: Spacing.lg,
          runSpacing: Spacing.md,
          crossAxisAlignment: WrapCrossAlignment.center,
          alignment: WrapAlignment.spaceBetween,
          children: [
            Semantics(header: true, child: Text('Styleguide', style: text.headlineLarge)),
            SegmentedButton<Brightness>(
              segments: const [
                ButtonSegment(value: Brightness.light, label: Text('Light')),
                ButtonSegment(value: Brightness.dark, label: Text('Dark')),
              ],
              selected: {brightness},
              onSelectionChanged: (s) => setState(() => _brightness = s.first),
            ),
          ],
        ),
        Text('ShuttleSense design tokens and shared components.', style: text.bodySmall),
        const SizedBox(height: Spacing.xl),
        _actionCards(p),
        const SizedBox(height: Spacing.lg),
        _Grid(
          children: [
            AppCard(
              title: 'Colour',
              child: _Swatches(p: p),
            ),
            AppCard(title: 'Type', subtitle: 'Outfit', child: _typeSamples(text)),
            AppCard(title: 'Buttons', child: _buttons(context)),
            AppCard(title: 'Controls', child: _controls()),
            AppCard(
              title: 'Stats',
              subtitle: 'Sample numbers',
              onExpand: () {},
              child: const Wrap(
                spacing: Spacing.xl,
                runSpacing: Spacing.lg,
                children: [
                  StatTile(label: 'Rallies', value: '24', icon: Icons.repeat),
                  StatTile(label: 'Max smash', value: '312', unit: 'km/h', icon: Icons.bolt),
                  StatTile(label: 'In-court', value: '87', unit: '%', icon: Icons.check),
                ],
              ),
            ),
            AppCard(title: 'Lists and progress', child: _lists(p)),
            AppCard(title: 'Status', child: _status()),
            const AppCard(
              title: 'Empty state',
              child: MessageView(
                icon: Icons.sports_tennis,
                message: 'No analyses yet',
                detail: 'Upload a rally and its results show up here.',
                action: FilledButton(onPressed: null, child: Text('Upload your first rally')),
              ),
            ),
            AppCard(
              title: 'Error and loading',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  MessageView(
                    icon: Icons.cloud_off,
                    message: 'Could not reach the server',
                    action: OutlinedButton(onPressed: () {}, child: const Text('Retry')),
                  ),
                  const Skeleton(width: 180),
                  const SizedBox(height: Spacing.sm),
                  const Skeleton(height: 48, radius: Radii.md),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _typeSamples(TextTheme text) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('Page title', style: text.headlineLarge),
      Text('Section heading', style: text.headlineSmall),
      Text('Card title', style: text.titleLarge),
      Text('Body text for explanations and lists.', style: text.bodyMedium),
      Text('Caption · 11 px', style: text.labelSmall),
      Text('128 km/h', style: text.displayMedium),
    ],
  );

  Widget _buttons(BuildContext context) => Wrap(
    spacing: Spacing.sm,
    runSpacing: Spacing.sm,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      FilledButton(onPressed: () {}, child: const Text('Primary')),
      FilledButton.tonal(onPressed: () {}, child: const Text('Secondary')),
      OutlinedButton(onPressed: () {}, child: const Text('Outlined')),
      TextButton(onPressed: () {}, child: const Text('Ghost')),
      const FilledButton(onPressed: null, child: Text('Disabled')),
      IconButton(
        onPressed: () {},
        tooltip: 'Notifications',
        icon: const Icon(Icons.notifications_none),
      ),
      FilledButton.tonal(
        onPressed: () => ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Analysis finished'))),
        child: const Text('Show toast'),
      ),
      FilledButton.tonal(
        onPressed: () => showDialog<void>(
          context: context,
          builder: (dialogContext) => Theme(
            data: Theme.of(context),
            child: AlertDialog(
              title: const Text('Delete this analysis?'),
              content: const Text('Its video and results are removed from the server.'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('Delete'),
                ),
              ],
            ),
          ),
        ),
        child: const Text('Show dialog'),
      ),
    ],
  );

  Widget _controls() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SegmentedButton<String>(
        segments: const [
          ButtonSegment(value: 'singles', label: Text('Singles')),
          ButtonSegment(value: 'doubles', label: Text('Doubles')),
        ],
        selected: {_match},
        onSelectionChanged: (s) => setState(() => _match = s.first),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Calibrate court'),
        value: _calibrate,
        onChanged: (v) => setState(() => _calibrate = v),
      ),
      Wrap(
        spacing: Spacing.sm,
        runSpacing: Spacing.sm,
        children: [
          for (final o in const ['Trail', 'Speed', 'Hits'])
            FilterChip(
              label: Text(o),
              selected: _overlays.contains(o),
              onSelected: (on) => setState(() => on ? _overlays.add(o) : _overlays.remove(o)),
            ),
          const Tooltip(
            message: 'Turn on Referee layer to enable',
            child: FilterChip(label: Text('Scoreboard'), onSelected: null),
          ),
        ],
      ),
      const SizedBox(height: Spacing.md),
      const TextField(decoration: InputDecoration(labelText: 'Server address')),
    ],
  );

  Widget _actionCards(AppPalette p) => _Grid(
    minWidth: 200,
    children: [
      PastelActionCard(
        color: p.lavender,
        icon: Icons.upload_file,
        title: 'Upload clip',
        description: 'Analyze a recorded rally.',
        badge: 'Last used',
        onTap: () {},
      ),
      PastelActionCard(
        color: p.sky,
        icon: Icons.videocam_outlined,
        title: 'Go live',
        description: 'Use a camera at the court.',
        onTap: () {},
      ),
      PastelActionCard(
        color: p.mint,
        icon: Icons.play_circle_outline,
        title: 'Watch & Analyze',
        description: 'Play a video while it is analyzed.',
        onTap: () {},
      ),
    ],
  );

  Widget _lists(AppPalette p) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      ListRow(
        leading: IconChip(icon: Icons.movie_outlined, background: p.sky),
        title: 'rally_03.mp4',
        subtitle: 'Processing · Shuttle tracking',
        trailing: const SizedBox(
          width: 96,
          child: GradientProgress(value: 0.62, label: 'Processing'),
        ),
      ),
      const ListRow(
        leading: IconChip(icon: Icons.person_outline),
        title: 'Near player',
        subtitle: '12 rallies · 140 strokes',
        value: '87',
      ),
      const SizedBox(height: Spacing.lg),
      const StepIndicator(steps: ['Video', 'Options', 'Calibrate'], current: 1),
    ],
  );

  // The blocked switch below never fires; DependentSwitch still needs a callback.
  static void _ignore(bool _) {}

  Widget _status() => const Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Wrap(
        spacing: Spacing.sm,
        runSpacing: Spacing.sm,
        children: [
          StatusPill(label: 'Done', tone: PillTone.good),
          StatusPill(label: 'Processing', tone: PillTone.info),
          StatusPill(label: 'Needs review', tone: PillTone.warning),
          StatusPill(label: 'Failed', tone: PillTone.bad),
          StatusPill(label: 'Queued'),
          StatusPill(label: 'Upload', tone: PillTone.info, dot: false),
        ],
      ),
      SizedBox(height: Spacing.md),
      HelperText('Choose a video to continue'),
      HelperText('Without calibration: no line calls or court map', warning: true),
      HelperText('Choose an MP4, MOV or AVI file', error: true),
      DependentSwitch(
        title: 'Referee layer',
        subtitle: 'Score and rally state',
        value: false,
        onChanged: _ignore,
        blockedBy: 'Calibrate court',
      ),
    ],
  );
}

/// Lays [children] out in as many equal columns as fit at [minWidth] each (at most three).
class _Grid extends StatelessWidget {
  const _Grid({required this.children, this.minWidth = 340});

  final List<Widget> children;
  final double minWidth;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final columns = (box.maxWidth / minWidth).floor().clamp(1, 3);
      final width = (box.maxWidth - Spacing.lg * (columns - 1)) / columns;
      return Wrap(
        spacing: Spacing.lg,
        runSpacing: Spacing.lg,
        children: [for (final c in children) SizedBox(width: width, child: c)],
      );
    },
  );
}

class _Swatches extends StatelessWidget {
  const _Swatches({required this.p});

  final AppPalette p;

  @override
  Widget build(BuildContext context) {
    final status = StatusColors.of(context);
    final named = {
      'ink': p.ink,
      'surface': p.surface,
      'surface-2': p.surface2,
      'text-2': p.text2,
      'text-3': p.text3,
      'lavender': p.lavender,
      'sky': p.sky,
      'mint': p.mint,
      'pink': p.pink,
      'peach': p.peach,
      'brand': p.brand,
      'info': p.info,
      'in': status.inCall,
      'out': status.outCall,
      'uncertain': status.uncertain,
      for (final (i, c) in p.chart.indexed) 'chart ${i + 1}': c,
    };
    final caption = Theme.of(context).textTheme.labelSmall;
    return Wrap(
      spacing: Spacing.sm,
      runSpacing: Spacing.md,
      children: [
        for (final MapEntry(key: name, value: colour) in named.entries)
          SizedBox(
            width: 64,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  height: 36,
                  decoration: BoxDecoration(
                    color: colour,
                    borderRadius: BorderRadius.circular(Radii.sm),
                    border: Border.all(color: p.text3.withValues(alpha: 0.3)),
                  ),
                ),
                Text(name, style: caption),
              ],
            ),
          ),
      ],
    );
  }
}
