import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router/app_router.dart';
import '../../data/api_client.dart';
import '../../data/models/health.dart';
import '../../data/models/job.dart';
import '../../data/repositories/analysis_repository.dart';
import '../../shared/widgets/page_scaffold.dart';
import '../../shared/widgets/section_card.dart';
import 'upload_controller.dart';

/// C2 / FR-C2: pick a rally video, choose overlays, upload with progress.
class UploadScreen extends ConsumerStatefulWidget {
  const UploadScreen({super.key});

  @override
  ConsumerState<UploadScreen> createState() => _UploadScreenState();
}

class _UploadScreenState extends ConsumerState<UploadScreen> {
  PlatformFile? _file;
  int _size = 0;
  int _sent = 0;
  double? _progress;
  CancelToken? _cancel;
  String? _error;

  bool get _isPhone =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  Future<void> _pick({bool gallery = false}) async {
    final files = await FilePicker.pickFiles(
      type: gallery ? FileType.video : FileType.custom,
      allowedExtensions: gallery ? null : const ['mp4', 'mov', 'avi'],
    );
    if (files.isEmpty) return;
    final size = await files.first.length() ?? 0;
    setState(() {
      _file = files.first;
      _size = size;
      _error = null;
    });
  }

  Future<void> _upload() async {
    final file = _file;
    if (file == null) return;
    if (_size > kLargeUploadBytes && !await _confirmLarge()) return;
    final api = ref.read(apiClientProvider);
    final options = ref.read(pendingJobOptionsProvider);
    setState(() {
      _progress = 0;
      _sent = 0;
      _error = null;
      _cancel = CancelToken();
    });
    try {
      final video = await api.uploadVideo(
        stream: file.readAsByteStream(),
        length: _size,
        filename: file.name,
        cancelToken: _cancel,
        onProgress: (sent, total) {
          if (mounted && total > 0) {
            setState(() {
              _sent = sent;
              _progress = sent / total;
            });
          }
        },
      );
      if (!mounted) return;
      if (options.calibrate) {
        context.go(Routes.calibrate(video.id));
      } else {
        final job = await api.createJob(videoId: video.id, options: options);
        if (mounted) context.go(Routes.job(job.id));
      }
    } on ApiException catch (e) {
      // The picked file is kept so the user can retry without choosing it again.
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) {
        setState(() {
          _progress = null;
          _cancel = null;
        });
      }
    }
  }

  Future<bool> _confirmLarge() async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Large video'),
          content: Text(
            'This file is ${formatBytes(_size)}. The server accepts up to 1 GB by default and '
            'clips up to ${kMaxDurationS ~/ 60} minutes. Trim it to the rally for a faster upload.',
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
    final uploading = _progress != null;
    final theme = Theme.of(context);

    return PageScaffold(
      title: 'New analysis',
      children: [
        SectionCard(
          title: '1. Rally video',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Singles rally, MP4/MOV/AVI, up to ${kMaxDurationS ~/ 60} minutes. Best results '
                'from a phone on a tripod, elevated and behind the baseline.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              if (_file != null)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.movie_outlined),
                  title: Text(_file!.name, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    formatBytes(_size) +
                        (_size > kLargeUploadBytes ? ' · larger than the 1 GB server limit' : ''),
                    style: _size > kLargeUploadBytes
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
                    label: Text(_file == null ? 'Choose video' : 'Choose another'),
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
                      reason: _disabledReason(name, options, health),
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
            value: '${(_progress! * 100).round()}%',
            child: LinearProgressIndicator(value: _progress),
          ),
          const SizedBox(height: 8),
          Text(
            'Uploading ${formatBytes(_sent)} of ${formatBytes(_size)} '
            '(${(_progress! * 100).round()}%)',
            textAlign: TextAlign.center,
          ),
          TextButton(onPressed: () => _cancel?.cancel(), child: const Text('Cancel')),
        ] else
          FilledButton.icon(
            onPressed: _file == null ? null : _upload,
            icon: const Icon(Icons.cloud_upload_outlined),
            label: Text(options.calibrate ? 'Upload and calibrate' : 'Upload and analyze'),
          ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
        ],
      ],
    );
  }
}

/// Why an overlay chip is greyed out, or null when it can be chosen (T4.3).
String? _disabledReason(String overlay, JobOptions options, Health? health) {
  if (!options.calibrate && kCourtOverlays.contains(overlay)) return 'Needs court calibration';
  if (overlay == 'score' && !options.referee) return 'Needs the referee layer';
  if (health != null && !health.supportsOverlay(overlay, kOverlayStage)) {
    return 'Not installed on this server';
  }
  return null;
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
