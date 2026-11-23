import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../data/models/video_info.dart';
import '../../data/repositories/analysis_repository.dart';
import '../../shared/widgets/page_scaffold.dart';
import '../../shared/widgets/surfaces.dart';
import '../../core/theme/tokens.dart';
import '../watch/watch_screen.dart' show formatWatchElapsed;
import '../mode/mode_screen.dart';

class PracticeScreen extends ConsumerStatefulWidget {
  const PracticeScreen({super.key, this.jobId});
  final String? jobId;
  @override
  ConsumerState<PracticeScreen> createState() => _PracticeScreenState();
}

class _PracticeScreenState extends ConsumerState<PracticeScreen> {
  VideoInfo? video;
  Map<String, dynamic>? job, result;
  List<List<double>> candidates = [];
  List<double>? selected;
  int selectionFrame = 0;
  String stroke = 'clear', arm = 'right';
  String? error;
  bool busy = false;
  final attempts = TextEditingController();
  Timer? timer;
  Player? player;
  VideoController? videoController;
  bool eventsDirty = false;
  bool loadingReport = false;
  bool controlBusy = false;

  @override
  void initState() {
    super.initState();
    if (widget.jobId != null) Future.microtask(() => loadJob(widget.jobId!));
  }

  @override
  void dispose() {
    timer?.cancel();
    attempts.dispose();
    player?.dispose();
    super.dispose();
  }

  Future<void> pick() async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['mp4', 'mov', 'avi'],
    );
    if (files.isEmpty || !mounted) return;
    final file = files.first;
    final size = await file.length();
    if (size == null) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final info = await ref
          .read(apiClientProvider)
          .uploadVideo(stream: file.readAsByteStream(), length: size, filename: file.name);
      if (!mounted) return;
      setState(() {
        video = info;
        job = null;
        result = null;
        selectionFrame = 0;
      });
      await findPlayers();
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> findPlayers() async {
    if (video == null) return;
    setState(() {
      busy = true;
      error = null;
      selected = null;
      candidates = [];
    });
    try {
      final data = await ref.read(apiClientProvider).practicePlayers(video!.id, selectionFrame);
      final values = (data['candidates'] as List)
          .map((p) => (p['bbox'] as List).map((n) => (n as num).toDouble()).toList())
          .toList();
      if (mounted) setState(() => candidates = values);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> start() async {
    final times = attempts.text.trim().isEmpty
        ? <double?>[]
        : attempts.text.split(',').map((s) => double.tryParse(s.trim())).toList();
    if (selected == null || times.any((v) => v == null || !v.isFinite)) {
      setState(() => error = 'Select a player and enter valid attempt times in seconds.');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final data = await ref.read(apiClientProvider).startPractice({
        'video_id': video!.id,
        'stroke': stroke,
        'arm': arm,
        'attempt_seconds': times,
        'selection_frame': selectionFrame,
        'selected_bbox': selected,
      });
      if (mounted) await loadJob(data['id'] as String);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> loadJob(String id) async {
    try {
      final data = await ref.read(apiClientProvider).practiceStatus(id);
      final info = video ?? await ref.read(apiClientProvider).getVideo(data['video_id'] as String);
      if (!mounted) return;
      final status = data['status'];
      final previousStatus = job?['status'];
      setState(() {
        job = data;
        video = info;
        if (previousStatus == null && data['practice_setup'] is Map) {
          final setup = data['practice_setup'] as Map;
          stroke = setup['stroke'] as String? ?? stroke;
          arm = setup['arm'] as String? ?? arm;
        }
      });
      timer?.cancel();
      if (status == 'queued' || status == 'running') {
        timer = Timer(const Duration(seconds: 1), () => loadJob(id));
      } else if (status == 'needs_selection' && previousStatus != 'needs_selection') {
        await player?.pause();
        setState(() => selectionFrame = data['practice_selection_frame'] as int);
        await findPlayers();
      } else if (status == 'done' && result == null) {
        setState(() {
          loadingReport = true;
          error = null;
        });
        try {
          final response = await ref.read(apiClientProvider).practiceResult(id);
          response.putIfAbsent('events', () => <dynamic>[]);
          if (!mounted) return;
          setState(() => result = response);
          final p = Player();
          final vc = VideoController(p);
          try {
            await p.open(
              Media(
                ref.read(apiClientProvider).practiceVideoUrl(id),
                httpHeaders: ref.read(apiClientProvider).authHeaders,
              ),
              play: false,
            );
            if (!mounted) {
              await p.dispose();
              return;
            }
            setState(() {
              player = p;
              videoController = vc;
            });
          } catch (e) {
            await p.dispose();
            if (mounted) setState(() => error = 'Rendered video could not be opened: $e');
          }
        } finally {
          if (mounted) setState(() => loadingReport = false);
        }
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  Future<void> resume() async {
    if (selected == null || job == null) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final data = await ref
          .read(apiClientProvider)
          .resumePractice(job!['id'] as String, selectionFrame, selected!);
      if (mounted) {
        setState(() {
          job = data;
          candidates = [];
          selected = null;
        });
        await loadJob(data['id'] as String);
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> controlAnalysis(String action) async {
    final id = job?['id'] as String?;
    if (id == null || controlBusy) return;
    setState(() {
      controlBusy = true;
      error = null;
    });
    try {
      await ref.read(apiClientProvider).controlPractice(id, action);
      await loadJob(id);
    } catch (e) {
      if (mounted) setState(() => error = 'Could not update analysis: $e');
    } finally {
      if (mounted) setState(() => controlBusy = false);
    }
  }

  Future<void> saveEvents() async {
    if (result == null || job == null) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final api = ref.read(apiClientProvider);
      final id = job!['id'] as String;
      await api.savePracticeEvents(id, result!['events'] as List);
      final updated = await api.practiceResult(id);
      if (mounted) {
        setState(() {
          result = updated;
          eventsDirty = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = video;
    final status = job?['status'] as String?;
    final selecting = info != null && (job == null || status == 'needs_selection');
    return PageScaffold(
      title: 'AI Coach',
      actions: const [ChangeModeButton()],
      children: [
        const Text(
          'Recorded practice for clear, smash or drop. Marked attempts are not verified shuttle contacts.',
        ),
        const SizedBox(height: 16),
        if (info == null)
          FilledButton(onPressed: busy ? null : pick, child: const Text('Choose practice video')),
        if (info != null) Text(info.filename, style: Theme.of(context).textTheme.titleMedium),
        if (selecting) ...[
          const SizedBox(height: 12),
          Text(
            status == 'needs_selection'
                ? 'Select the player to continue this older session.'
                : 'Choose the player in the frame.',
          ),
          Slider(
            min: status == 'needs_selection'
                ? (job!['practice_selection_frame'] as int).toDouble()
                : 0,
            value: selectionFrame.toDouble(),
            max: (info.numFrames - 1)
                .clamp(
                  status == 'needs_selection' ? (job!['practice_selection_frame'] as int) + 1 : 1,
                  10000000,
                )
                .toDouble(),
            onChanged:
                busy ||
                    info.numFrames <= 1 ||
                    (status == 'needs_selection' &&
                        (job!['practice_selection_frame'] as int) >= info.numFrames - 1)
                ? null
                : (v) => setState(() {
                    selectionFrame = v.round();
                    selected = null;
                    candidates = [];
                  }),
            onChangeEnd: (_) => findPlayers(),
          ),
          Text('Frame $selectionFrame (${(selectionFrame / info.fps).toStringAsFixed(1)} s)'),
          if (job == null) ...[
            OutlinedButton.icon(
              onPressed: busy
                  ? null
                  : () {
                      final time = (selectionFrame / info.fps).toStringAsFixed(3);
                      attempts.text = attempts.text.trim().isEmpty
                          ? time
                          : '${attempts.text.trim()}, $time';
                    },
              icon: const Icon(Icons.add_circle_outline),
              label: const Text('Mark attempt at this frame'),
            ),
            const Text('Select the player at or before the first marked attempt.'),
          ] else
            const Text(
              'Move forward if the player is hidden; skipped attempts will be unavailable.',
            ),
          AspectRatio(
            aspectRatio: info.aspectRatio,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final sx = constraints.maxWidth / info.width,
                    sy = constraints.maxHeight / info.height;
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.network(
                      ref.read(apiClientProvider).frameUrl(info.id, selectionFrame, maxWidth: 3840),
                      fit: BoxFit.fill,
                    ),
                    for (final box in candidates)
                      Positioned(
                        left: box[0] * sx,
                        top: box[1] * sy,
                        width: box[2] * sx,
                        height: box[3] * sy,
                        child: GestureDetector(
                          onTap: () => setState(() => selected = box),
                          child: Container(
                            decoration: BoxDecoration(
                              border: Border.all(
                                color: identical(box, selected) ? Colors.green : Colors.amber,
                                width: 3,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
          if (candidates.isEmpty && !busy)
            const Text('No player detected. Choose another frame or check the models.'),
          if (job == null) ...[
            DropdownButton<String>(
              value: stroke,
              items: [
                'clear',
                'smash',
                'drop',
              ].map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(),
              onChanged: (s) => setState(() => stroke = s!),
            ),
            DropdownButton<String>(
              value: arm,
              items: [
                'right',
                'left',
              ].map((s) => DropdownMenuItem(value: s, child: Text('$s racket arm'))).toList(),
              onChanged: (s) => setState(() => arm = s!),
            ),
            TextField(
              controller: attempts,
              decoration: const InputDecoration(
                labelText: 'Optional manual attempt times in seconds, separated by commas',
                hintText: '1.2, 3.5, 6.0',
              ),
            ),
            FilledButton(
              onPressed: busy || selected == null ? null : start,
              child: const Text('Confirm and analyze'),
            ),
          ] else
            FilledButton(
              onPressed: busy || selected == null ? null : resume,
              child: const Text('Resume with selected player'),
            ),
        ],
        if (status == 'queued' || status == 'running') ...[
          const SizedBox(height: Spacing.lg),
          if (job?['preview'] is Map && (job!['preview'] as Map)['jpeg'] is String)
            ClipRRect(
              borderRadius: BorderRadius.circular(Radii.lg),
              child: AspectRatio(
                aspectRatio: info!.aspectRatio,
                child: Image.memory(
                  base64Decode((job!['preview'] as Map)['jpeg'] as String),
                  gaplessPlayback: true,
                  fit: BoxFit.fill,
                ),
              ),
            ),
          const SizedBox(height: Spacing.lg),
          Builder(
            builder: (context) {
              final control = job?['control'] as Map? ?? const {};
              final paused = control['paused'] == true;
              final stopping = control['stopping'] == true;
              final rendering = job?['current_stage'] == 'render';
              final frame = ((job?['preview'] as Map?)?['frame'] as num?)?.toInt();
              final started = DateTime.tryParse(job?['started_at'] as String? ?? '');
              final elapsed = started == null ? Duration.zero : DateTime.now().difference(started);
              final progress = ((job?['progress'] as num?)?.toDouble() ?? 0).clamp(0.0, 1.0);
              final label = status == 'queued'
                  ? 'Waiting in queue'
                  : stopping
                  ? 'Saving session?'
                  : paused
                  ? 'Paused'
                  : rendering
                  ? 'Rendering video?'
                  : 'Catching up?';
              return AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: Spacing.xs,
                  children: [
                    Text(
                      '$label${frame == null ? '' : ' ? ${(frame / info!.fps).toStringAsFixed(1)} s / ${(info.numFrames / info.fps).toStringAsFixed(1)} s'}',
                    ),
                    Text(
                      'Elapsed: ${formatWatchElapsed(elapsed.isNegative ? Duration.zero : elapsed)} (includes pauses)',
                    ),
                    LinearProgressIndicator(value: status == 'queued' ? null : progress),
                    Text('${(progress * 100).round()}% ? ${rendering ? 'Rendering' : 'Analyzing'}'),
                    const Text('The preview shows the latest analyzed frame.'),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: Spacing.lg),
          if (status == 'running')
            Builder(
              builder: (context) {
                final control = job?['control'] as Map? ?? const {};
                final paused = control['paused'] == true;
                final stopping = control['stopping'] == true;
                return Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton(
                      onPressed: controlBusy || stopping
                          ? null
                          : () => controlAnalysis(paused ? 'resume' : 'pause'),
                      child: Text(paused ? 'Play' : 'Pause'),
                    ),
                    OutlinedButton(
                      onPressed: controlBusy || stopping ? null : () => controlAnalysis('stop'),
                      child: const Text('Stop and save'),
                    ),
                  ],
                );
              },
            ),
        ] else if (busy && status != 'done') ...[
          const SizedBox(height: Spacing.lg),
          const LinearProgressIndicator(),
          const Text('Preparing video and player selection?'),
        ],
        if (status == 'failed') Text('Analysis failed: ${job?['error']}'),
        if (status == 'done' && loadingReport) ...[
          const LinearProgressIndicator(),
          const Text('Analysis and rendering complete. Loading AI Coach…'),
        ],
        if (status == 'done' && result == null && !loadingReport && error != null)
          OutlinedButton(
            onPressed: () => loadJob(job!['id'] as String),
            child: const Text('Retry coaching report'),
          ),
        if (videoController != null) ...[
          const SizedBox(height: 16),
          AspectRatio(
            aspectRatio: info!.aspectRatio,
            child: Video(controller: videoController!),
          ),
        ],
        if (result != null) ...[
          if (result!['stopped_early'] == true)
            const Text(
              'This session was stopped early; the video and report cover the analyzed portion.',
            ),
          const SizedBox(height: 16),
          Text('Review stroke events', style: Theme.of(context).textTheme.titleLarge),
          const Text(
            'Automatic predictions are estimates. Confirm, correct or remove them before updating the report.',
          ),
          const Text('Detailed pose observations currently cover clear, smash and drop.'),
          if (result!['shuttle_tracking_available'] != true)
            const Text(
              'Shuttle tracking was unavailable; automatic stroke detection may be incomplete.',
            ),
          for (final event in ((result!['events'] as List?) ?? []))
            ListTile(
              title: Text(
                '${event['time_s']} s · ${event['source']} · ${event['model'] ?? 'user label'}'
                '${event['confidence'] is num ? ' · ${((event['confidence'] as num) * 100).toStringAsFixed(0)}% confidence' : ''}',
              ),
              subtitle: DropdownButton<String>(
                value: event['stroke'] as String?,
                hint: const Text('Choose stroke'),
                items: [
                  'clear',
                  'smash',
                  'drop',
                  'net_shot',
                  'lift',
                  'serve',
                ].map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(),
                onChanged: (value) => setState(() {
                  event['stroke'] = value;
                  event['confirmed'] = true;
                  eventsDirty = true;
                }),
              ),
              leading: Checkbox(
                value: event['confirmed'] == true,
                onChanged: (value) => setState(() {
                  event['confirmed'] = value;
                  eventsDirty = true;
                }),
              ),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Remove event',
                onPressed: () => setState(() {
                  (result!['events'] as List).remove(event);
                  eventsDirty = true;
                }),
              ),
              onTap: () =>
                  player?.seek(Duration(milliseconds: ((event['time_s'] as num) * 1000).round())),
            ),
          Wrap(
            spacing: 12,
            children: [
              OutlinedButton(
                onPressed: () => setState(() {
                  final seconds = (player?.state.position.inMilliseconds ?? 0) / 1000;
                  (result!['events'] as List).add({
                    'id': 'manual-${DateTime.now().microsecondsSinceEpoch}',
                    'time_s': seconds,
                    'stroke': stroke,
                    'source': 'manual',
                    'confirmed': true,
                  });
                  eventsDirty = true;
                }),
                child: const Text('Add event at playback position'),
              ),
              FilledButton(
                onPressed: busy || !eventsDirty ? null : saveEvents,
                child: const Text('Save events and update report'),
              ),
            ],
          ),
          if (eventsDirty) const Text('Unsaved event changes are not included in the report.'),
          const SizedBox(height: 16),
          if ((result!['unobserved_frames'] as num? ?? 0) > 0)
            const Text(
              'The selected player was not confidently tracked in some frames; those moments are excluded from player analysis.',
            ),
          Text('Coaching report', style: Theme.of(context).textTheme.titleLarge),
          Text('${(result!['report'] as Map)['summary']}'),
          Text('Generated by: ${(result!['report'] as Map)['generated_by']}'),
          Text('${(result!['report'] as Map)['limitation']}'),
          if ((result!['report'] as Map)['ai_overall_guidance'] != null)
            Text('AI guidance: ${(result!['report'] as Map)['ai_overall_guidance']}'),
          for (final item in (((result!['report'] as Map)['ai_moment_guidance'] as List?) ?? []))
            ListTile(
              title: Text('AI guidance: ${item['text']}'),
              subtitle: Text(
                '${item['time_s']} s · knowledge: ${(item['knowledge_ids'] as List).join(', ')} · review against the evidence',
              ),
              onTap: () =>
                  player?.seek(Duration(milliseconds: ((item['time_s'] as num) * 1000).round())),
            ),
          for (final item in ((result!['report'] as Map)['evidence'] as List))
            ListTile(
              title: Text('${item['description']} ${item['value']} ${item['unit'] ?? ''}'),
              subtitle: Text('${item['moment_s']} s'),
              onTap: () =>
                  player?.seek(Duration(milliseconds: ((item['moment_s'] as num) * 1000).round())),
            ),
          for (final item in ((result!['report'] as Map)['guidance'] as List))
            ListTile(
              title: Text('${item['text']}'),
              subtitle: Text('${item['source']}'),
              onTap: (item['moments'] as List).isEmpty
                  ? null
                  : () => player?.seek(
                      Duration(
                        milliseconds: (((item['moments'] as List).first as num) * 1000).round(),
                      ),
                    ),
            ),
          for (final attempt in (result!['observations'] as List))
            for (final observation in (attempt['observations'] as List))
              if (observation['status'] == 'unavailable')
                ListTile(
                  title: Text('Unavailable: ${observation['description']}'),
                  subtitle: Text('${observation['moment_s']} s'),
                  onTap: () => player?.seek(
                    Duration(milliseconds: ((observation['moment_s'] as num) * 1000).round()),
                  ),
                ),
        ],
        if (error != null)
          Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
      ],
    );
  }
}
