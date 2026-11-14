import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router/app_router.dart';
import '../../data/models/job.dart';
import '../../data/repositories/analysis_repository.dart';
import '../../shared/widgets/page_scaffold.dart';
import '../mode/mode_screen.dart';
import '../../shared/widgets/section_card.dart';
import '../../shared/widgets/match_setup_field.dart';
import '../../shared/widgets/start_score_field.dart';
import '../../shared/widgets/stroke_model_field.dart';
import 'upload_controller.dart';

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
    final warnings = [
      if (upload.durationS != null) _minutes(upload.durationS!),
      formatBytes(upload.size),
      if (upload.tooLong) 'longer than the ${kMaxDurationS ~/ 60}-minute server limit',
      if (upload.large) 'larger than the 1 GB server limit',
    ];

    return PageScaffold(
      title: 'New analysis',
      actions: const [SwitchModeButton()],
      children: [
        SectionCard(
          title: '1. Rally video',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Singles or doubles rally, MP4/MOV/AVI, up to ${kMaxDurationS ~/ 60} minutes. '
                'Best results from a phone on a tripod, elevated and behind the baseline.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              if (file != null)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.movie_outlined),
                  title: Text(file.name, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    warnings.join(' · '),
                    style: upload.large || upload.tooLong
                        ? TextStyle(color: theme.colorScheme.error)
                        : null,
                  ),
                ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (_isPhone)
                    OutlinedButton.icon(
                      onPressed: uploading ? null : () => _pick(gallery: true),
                      icon: const Icon(Icons.photo_library_outlined),
                      label: const Text('From gallery'),
                    ),
                  OutlinedButton.icon(
                    onPressed: uploading ? null : _pick,
                    icon: const Icon(Icons.video_library_outlined),
                    label: Text(file == null ? 'Choose video' : 'Choose another'),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        SectionCard(
          title: '2. Options',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Calibrate court'),
                subtitle: const Text('Tap 4 court corners to enable minimap, speed and in/out'),
                value: options.calibrate,
                onChanged: (v) => notifier.set(options.copyWith(calibrate: v)),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Referee layer (beta)'),
                subtitle: const Text('Rally state and assisted scoreboard; needs calibration'),
                value: options.referee,
                onChanged: options.calibrate
                    ? (v) => notifier.set(options.copyWith(referee: v))
                    : null,
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
                ),
              StrokeModelField(
                value: options.strokeModel,
                health: health,
                onChanged: notifier.setStrokeModel,
              ),
              const SizedBox(height: 8),
              Text('Overlays', style: theme.textTheme.labelLarge),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final MapEntry(key: name, value: label) in kOverlays.entries)
                    _OverlayChip(
                      name: name,
                      label: label,
                      selected: options.overlays.contains(name),
                      reason: overlayDisabledReason(name, options, health),
                      onSelected: (on) => notifier.toggleOverlay(name, on),
                    ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        if (uploading) ...[
          Semantics(
            label: 'Upload progress',
            value: '${(upload.progress! * 100).round()}%',
            child: LinearProgressIndicator(value: upload.progress),
          ),
          const SizedBox(height: 8),
          Text(
            'Uploading ${formatBytes(upload.sent)} of ${formatBytes(upload.size)} '
            '(${(upload.progress! * 100).round()}%)',
            textAlign: TextAlign.center,
          ),
          TextButton(onPressed: _upload.cancel, child: const Text('Cancel')),
        ] else
          FilledButton.icon(
            onPressed: file == null ? null : _start,
            icon: const Icon(Icons.cloud_upload_outlined),
            label: Text(options.calibrate ? 'Upload and calibrate' : 'Upload and analyze'),
          ),
        if (upload.error != null) ...[
          const SizedBox(height: 12),
          Text(upload.error!, style: TextStyle(color: theme.colorScheme.error)),
        ],
      ],
    );
  }
}

/// "4:05" for 245 seconds.
String _minutes(double seconds) {
  final s = seconds.round();
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
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
