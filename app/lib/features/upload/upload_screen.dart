import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router/app_router.dart';
import '../../data/api_client.dart';
import '../../data/models/job.dart';
import '../../data/repositories/analysis_repository.dart';
import '../../shared/widgets/page_scaffold.dart';
import '../../shared/widgets/section_card.dart';

/// C2 / FR-C2: pick a rally video, choose overlays, upload with progress.
class UploadScreen extends ConsumerStatefulWidget {
  const UploadScreen({super.key});

  @override
  ConsumerState<UploadScreen> createState() => _UploadScreenState();
}

class _UploadScreenState extends ConsumerState<UploadScreen> {
  PlatformFile? _file;
  int _size = 0;
  double? _progress;
  CancelToken? _cancel;
  String? _error;

  Future<void> _pick() async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['mp4', 'mov', 'avi'],
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
    final api = ref.read(apiClientProvider);
    final options = ref.read(pendingJobOptionsProvider);
    setState(() {
      _progress = 0;
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
          if (mounted && total > 0) setState(() => _progress = sent / total);
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

  @override
  Widget build(BuildContext context) {
    final options = ref.watch(pendingJobOptionsProvider);
    final notifier = ref.read(pendingJobOptionsProvider.notifier);
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
                'Singles rally, MP4/MOV/AVI, up to 5 minutes. Best results from a phone on a '
                'tripod, elevated and behind the baseline.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              if (_file != null)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.movie_outlined),
                  title: Text(_file!.name, overflow: TextOverflow.ellipsis),
                  subtitle: Text('${(_size / (1024 * 1024)).toStringAsFixed(1)} MB'),
                ),
              OutlinedButton.icon(
                onPressed: uploading ? null : _pick,
                icon: const Icon(Icons.video_library_outlined),
                label: Text(_file == null ? 'Choose video' : 'Choose another'),
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
                onChanged: (v) => notifier.state = JobOptions(
                  overlays: options.overlays,
                  referee: v && options.referee,
                  calibrate: v,
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Referee layer (beta)'),
                subtitle: const Text('Rally state and assisted scoreboard; needs calibration'),
                value: options.referee,
                onChanged: options.calibrate
                    ? (v) => notifier.state = JobOptions(
                        overlays: options.overlays,
                        referee: v,
                        calibrate: options.calibrate,
                      )
                    : null,
              ),
              const SizedBox(height: 8),
              Text('Overlays', style: theme.textTheme.labelLarge),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final entry in kOverlays.entries)
                    FilterChip(
                      label: Text(entry.value),
                      selected: options.overlays.contains(entry.key),
                      onSelected: (selected) {
                        final next = {...options.overlays};
                        selected ? next.add(entry.key) : next.remove(entry.key);
                        notifier.state = JobOptions(
                          overlays: next,
                          referee: options.referee,
                          calibrate: options.calibrate,
                        );
                      },
                    ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        if (uploading) ...[
          LinearProgressIndicator(value: _progress),
          const SizedBox(height: 8),
          Text('Uploading ${(_progress! * 100).round()}%', textAlign: TextAlign.center),
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
