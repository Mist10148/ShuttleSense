import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router/app_router.dart';
import '../../data/models/job.dart';
import '../../data/repositories/analysis_repository.dart';
import '../../shared/widgets/page_scaffold.dart';
import '../../shared/widgets/surfaces.dart';
import '../mode/mode_screen.dart';
import '../../data/models/health.dart';
import '../../shared/widgets/dependent_switch.dart';
import '../../shared/widgets/helper_text.dart';
import '../../shared/widgets/step_indicator.dart';
import '../../shared/widgets/section_card.dart';
import '../../shared/widgets/match_setup_field.dart';
import '../../shared/widgets/start_score_field.dart';
import '../../shared/widgets/stroke_model_field.dart';
import 'upload_controller.dart';
import '../../core/theme/tokens.dart';
import '../../shared/widgets/tactile.dart';
import '../../ui/depth.dart';

/// C2 / FR-C2: pick a rally video, choose overlays, upload with progress.
class UploadScreen extends ConsumerStatefulWidget {
  const UploadScreen({super.key});

  @override
  ConsumerState<UploadScreen> createState() => _UploadScreenState();
}

class _UploadScreenState extends ConsumerState<UploadScreen> {
  late final UploadNotifier _upload = ref.read(uploadProvider.notifier);

  bool get _isPhone =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  @override
  void initState() {
    super.initState();
    _upload; // read now: ref cannot be used in dispose
  }

  Future<void> _pick({bool gallery = false}) async {
    final files = await FilePicker.pickFiles(
      type: gallery ? FileType.video : FileType.custom,
      allowedExtensions: gallery ? null : const ['mp4', 'mov', 'avi'],
    );
    if (files.isEmpty) return;
    await _upload.choose(files.first, web: kIsWeb);
  }

  @override
  void dispose() {
    // Leaving the screen (Back, Change server, switching to Live) stops the upload;
    // otherwise it would finish with nobody left to start the job, leaving an orphan video
    // on the server. Switching to another tab keeps this screen mounted, so it carries on.
    _upload.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    final state = ref.read(uploadProvider);
    if (state.file == null) return;
    if ((state.large || state.tooLong) && !await _confirmLarge(state)) return;
    final done = await _upload.upload();
    if (done == null || !mounted) return;
    final job = done.job;
    context.go(job == null ? Routes.calibrate(done.videoId) : Routes.job(job.id));
  }

  Future<bool> _confirmLarge(UploadState state) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(state.tooLong ? 'Long video' : 'Large video'),
          content: Text(
            '${state.tooLong ? 'This clip is ${_minutes(state.durationS!)} long' : 'This file is ${formatBytes(state.size)}'}. '
            'The server accepts clips up to ${kMaxDurationS ~/ 60} minutes and 1 GB by default, '
            'and refuses longer ones after the upload. Trim it to the rally first.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Upload anyway'),
            ),
          ],
        ),
      ) ??
      false;

  @override
  Widget build(BuildContext context) {
    final options = ref.watch(pendingJobOptionsProvider);
    final notifier = ref.read(pendingJobOptionsProvider.notifier);
    final health = ref.watch(healthProvider).valueOrNull;
    final upload = ref.watch(uploadProvider);
    final file = upload.file;
    final uploading = upload.uploading;
    final theme = Theme.of(context);
    final badFormat =
        file != null && !_kVideoExtensions.contains(file.name.split('.').last.toLowerCase());
    final details = [
      if (upload.durationS != null) _minutes(upload.durationS!),
      formatBytes(upload.size),
      if (upload.tooLong) 'longer than the ${kMaxDurationS ~/ 60}-minute server limit',
      if (upload.large) 'larger than the 1 GB server limit',
    ];
    final blocked = switch (file) {
      null => 'Choose a video to continue',
      _ when badFormat => 'Choose an MP4, MOV or AVI file to continue',
      _ => null,
    };
    final step = file == null || badFormat ? 0 : (uploading ? 2 : 1);
    final showStrokeModel = health == null || health.strokeModels != null;
    final model = kStrokeModels[resolveStrokeModel(options.strokeModel, health)];
    final pickButtons = [
      if (_isPhone)
        OutlinedButton.icon(
          onPressed: uploading ? null : () => _pick(gallery: true),
          icon: const Icon(Icons.photo_library_outlined),
          label: const Text('From gallery'),
        ),
      if (file == null)
        FilledButton.tonalIcon(
          onPressed: uploading ? null : _pick,
          icon: const Icon(Icons.video_library_outlined),
          label: const Text('Choose video'),
        )
      else
        OutlinedButton.icon(
          onPressed: uploading ? null : _pick,
          icon: const Icon(Icons.swap_horiz),
          label: const Text('Replace'),
        ),
    ];

    return PageScaffold(
      title: 'New analysis',
      actions: const [ChangeModeButton()],
      children: [
        StepIndicator(
          steps: ['Video', 'Options', options.calibrate ? 'Upload & calibrate' : 'Upload'],
          current: step,
        ),
        const SizedBox(height: Spacing.xl),
        SectionCard(
          title: '1. Rally video',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (file == null)
                VideoDropZone(actions: pickButtons)
              else ...[
                VideoFileRow(
                  name: file.name,
                  details: details.join(' · '),
                  warn: upload.large || upload.tooLong,
                  actions: pickButtons,
                ),
                if (badFormat)
                  const HelperText(
                    'This file type is not supported. Use MP4, MOV or AVI.',
                    error: true,
                  ),
              ],
            ],
          ),
        ),
        const SizedBox(height: Spacing.lg),
        SectionCard(
          title: '2. Options',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TactileSwitchTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Calibrate court'),
                subtitle: const Text(
                  'Tap 4 court corners for player detection and court features. Recommended.',
                ),
                value: options.calibrate,
                onChanged: (v) => notifier.set(options.copyWith(calibrate: v)),
              ),
              if (!options.calibrate)
                const HelperText(
                  'Without calibration players are not detected: Skeletons and Player boxes '
                  'stay empty, and Court outline, Minimap, Speed, Scoreboard and the Referee '
                  'layer are off.',
                  warning: true,
                ),
              DependentSwitch(
                title: 'Referee layer (beta)',
                subtitle: 'Rally state and assisted scoreboard',
                value: options.referee,
                blockedBy: options.calibrate ? null : 'Calibrate court',
                // The scoreboard overlay is what the referee layer draws: switch it on too.
                onChanged: (v) => notifier.set(
                  options.copyWith(
                    referee: v,
                    overlays: v ? {...options.overlays, 'score'} : options.overlays,
                  ),
                ),
              ),
              if (options.calibrate && options.referee)
                StartScoreField(
                  key: ObjectKey(file), // a new clip starts from 0-0 again
                  value: options.startScore,
                  doubles: options.match.doubles,
                  onChanged: notifier.setStartScore,
                ),
              if (options.calibrate && options.referee)
                MatchSetupField(
                  value: options.match,
                  onChanged: notifier.setMatch,
                  showCourt: true,
                  showChangeEnds: health?.supportsChangeEnds ?? false,
                ),
              const SizedBox(height: Spacing.md),
              _OverlayPicker(options: options, health: health, notifier: notifier),
              if (showStrokeModel)
                Theme(
                  // No divider lines: the card already frames the section.
                  data: theme.copyWith(dividerColor: Colors.transparent),
                  child: ExpansionTile(
                    tilePadding: const EdgeInsets.symmetric(horizontal: Spacing.md),
                    childrenPadding: const EdgeInsets.fromLTRB(
                      Spacing.md,
                      0,
                      Spacing.md,
                      Spacing.md,
                    ),
                    title: const Text('Advanced'),
                    subtitle: Text('Stroke model: ${model ?? 'server default'}'),
                    children: [
                      StrokeModelField(
                        value: options.strokeModel,
                        health: health,
                        onChanged: notifier.setStrokeModel,
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: Spacing.xl),
        if (uploading) ...[
          Semantics(
            label: 'Upload progress',
            value: '${(upload.progress! * 100).round()}%',
            child: LinearProgressIndicator(value: upload.progress),
          ),
          const SizedBox(height: Spacing.sm),
          Text(
            'Uploading ${formatBytes(upload.sent)} of ${formatBytes(upload.size)} '
            '(${(upload.progress! * 100).round()}%)',
            textAlign: TextAlign.center,
          ),
          TextButton(onPressed: _upload.cancel, child: const Text('Cancel')),
        ] else ...[
          FilledButton.icon(
            onPressed: blocked == null ? _start : null,
            icon: const Icon(Icons.cloud_upload_outlined),
            label: Text(options.calibrate ? 'Upload and calibrate' : 'Upload and analyze'),
          ),
          if (blocked != null) HelperText(blocked),
        ],
        if (upload.error != null) ...[
          const SizedBox(height: Spacing.md),
          HelperText(upload.error!, error: true),
        ],
      ],
    );
  }
}

/// What the file picker offers outside the phone gallery; a gallery pick can be anything.
const _kVideoExtensions = {'mp4', 'mov', 'avi'};

/// "4:05" for 245 seconds.
String _minutes(double seconds) {
  final s = seconds.round();
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

/// The empty video slot: a dashed outline with what the server accepts and the pick buttons.
class VideoDropZone extends StatelessWidget {
  const VideoDropZone({super.key, required this.actions, this.title, this.detail});

  final List<Widget> actions;

  /// Override the default rally wording (the AI Coach asks for a practice video).
  final String? title;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final text = Theme.of(context).textTheme;
    return InsetBox(
      radius: Radii.lg + 6,
      padding: const EdgeInsets.all(Spacing.sm + 2),
      child: CustomPaint(
        painter: _DashedBorderPainter(color: p.text3, radius: Radii.lg),
        child: Padding(
          padding: const EdgeInsets.all(Spacing.lg),
          child: Column(
            children: [
              const IconWell(icon: Icons.movie_outlined, size: 44, iconSize: 22),
              const SizedBox(height: Spacing.sm),
              Text(
                title ?? 'Choose a rally video',
                style: text.titleMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: Spacing.xs),
              Text(
                detail ??
                    'Singles or doubles rally, MP4/MOV/AVI, up to ${kMaxDurationS ~/ 60} minutes. '
                        'Best results from a phone on a tripod, elevated and behind the baseline.',
                style: text.bodySmall?.copyWith(color: p.text2),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: Spacing.md),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: Spacing.sm,
                runSpacing: Spacing.sm,
                children: actions,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The chosen video: name, length and size (in the error colour past a server limit), and
/// the Replace button.
/// A chosen video: a tinted icon, the file name, its details, and actions (change it).
class VideoFileRow extends StatelessWidget {
  const VideoFileRow({
    super.key,
    required this.name,
    required this.details,
    required this.warn,
    required this.actions,
  });

  final String name;
  final String details;
  final bool warn;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final theme = Theme.of(context);
    final info = Row(
      children: [
        IconChip(icon: Icons.movie_outlined, background: p.mint),
        const SizedBox(width: Spacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name,
                style: theme.textTheme.titleMedium,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                details,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: warn ? theme.colorScheme.error : p.text2,
                ),
              ),
            ],
          ),
        ),
      ],
    );
    final buttons = Wrap(spacing: Spacing.sm, runSpacing: Spacing.sm, children: actions);
    // The actions sit beside the name when there is room, else under it (a phone).
    return LayoutBuilder(
      builder: (context, box) => actions.isEmpty
          ? info
          : box.maxWidth >= 480
          ? Row(
              children: [
                Expanded(child: info),
                const SizedBox(width: Spacing.sm),
                buttons,
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: Spacing.sm,
              children: [info, buttons],
            ),
    );
  }
}

class _DashedBorderPainter extends CustomPainter {
  const _DashedBorderPainter({required this.color, required this.radius});

  final Color color;
  final double radius;

  static const _dash = 6.0;
  static const _gap = 5.0;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final outline = Path()
      ..addRRect(RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius)));
    for (final metric in outline.computeMetrics()) {
      for (var d = 0.0; d < metric.length; d += _dash + _gap) {
        canvas.drawPath(metric.extractPath(d, d + _dash), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorderPainter old) => old.color != color || old.radius != radius;
}

/// Overlay chips in groups, with All / None. A chip that cannot be chosen says why, both in
/// its tooltip and in a line under the groups.
class _OverlayPicker extends StatelessWidget {
  const _OverlayPicker({required this.options, required this.health, required this.notifier});

  final JobOptions options;
  final Health? health;
  final JobOptionsNotifier notifier;

  static const _groups = <String, List<String>>{
    'Tracking': ['trail', 'speed', 'hits'],
    'Players': ['pose', 'boxes'],
    'Court': ['court', 'minimap'],
    'Match': ['strokes', 'score'],
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reasons = {
      for (final name in kOverlays.keys) name: overlayDisabledReason(name, options, health),
    };
    final blocked = [
      for (final MapEntry(key: name, value: reason) in reasons.entries)
        if (reason != null) '${kOverlays[name]} (${reason.toLowerCase()})',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text('Overlays', style: theme.textTheme.labelLarge)),
            // All / None in a tray; the one in effect is raised.
            DepthSegmented<String>(
              emptySelectionAllowed: true,
              segments: const [
                ButtonSegment(value: 'all', label: Text('All')),
                ButtonSegment(value: 'none', label: Text('None')),
              ],
              selected: {
                if (options.overlays.length == kOverlays.length) 'all',
                if (options.overlays.isEmpty) 'none',
              },
              // Tapping All or None applies it; the raised segment shows which is in effect.
              onSelectionChanged: (picked) {
                if (picked.contains('all') && options.overlays.length != kOverlays.length) {
                  notifier.set(options.copyWith(overlays: kOverlays.keys.toSet()));
                } else if (picked.contains('none') && options.overlays.isNotEmpty) {
                  notifier.set(options.copyWith(overlays: {}));
                }
              },
              compact: true,
            ),
          ],
        ),
        for (final MapEntry(key: group, value: names) in _groups.entries) ...[
          const SizedBox(height: Spacing.sm),
          Text(
            group,
            style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: Spacing.xs),
          // Each group of options sits in its own recessed well (lib/ui/depth.dart).
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: InsetBox(
              radius: 14,
              padding: const EdgeInsets.all(Spacing.xs + 2),
              child: Wrap(
                spacing: Spacing.sm,
                runSpacing: Spacing.sm,
                children: [
                  for (final name in names)
                    _OverlayChip(
                      name: name,
                      label: kOverlays[name]!,
                      selected: options.overlays.contains(name),
                      reason: reasons[name],
                      onSelected: (on) => notifier.toggleOverlay(name, on),
                    ),
                ],
              ),
            ),
          ),
        ],
        if (blocked.isNotEmpty) HelperText('Unavailable: ${blocked.join('; ')}.'),
      ],
    );
  }
}

class _OverlayChip extends StatelessWidget {
  const _OverlayChip({
    required this.name,
    required this.label,
    required this.selected,
    required this.reason,
    required this.onSelected,
  });

  final String name;
  final String label;
  final bool selected;
  final String? reason;
  final ValueChanged<bool> onSelected;

  @override
  Widget build(BuildContext context) {
    final chip = FilterChip(
      label: Text(label),
      selected: selected && reason == null,
      onSelected: reason == null ? onSelected : null,
    );
    return reason == null ? chip : Tooltip(message: reason!, child: chip);
  }
}
