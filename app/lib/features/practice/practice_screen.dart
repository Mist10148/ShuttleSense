import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../data/api_client.dart';
import '../../data/models/video_info.dart';
import '../../data/repositories/analysis_repository.dart';
import '../../shared/widgets/page_scaffold.dart';
import '../../shared/widgets/surfaces.dart';
import '../../core/theme/tokens.dart';
import '../watch/watch_screen.dart' show formatWatchElapsed, watchFrameDelay, WatchOverlay;
import '../mode/mode_screen.dart';
import 'coach_guide_panel.dart';
import '../calibration/calibration_screen.dart' show Corner, CornerCanvas;
import '../watch/court_geometry.dart' show fullToSingles, singlesToFull, FullCourtPreview;

class PracticeScreen extends ConsumerStatefulWidget {
  const PracticeScreen({super.key, this.jobId, this.channelFactory});
  final String? jobId;
  final WebSocketChannel Function(Uri)? channelFactory;
  @override
  ConsumerState<PracticeScreen> createState() => _PracticeScreenState();
}

class _PracticeScreenState extends ConsumerState<PracticeScreen> {
  VideoInfo? video;
  Map<String, dynamic>? job, result, guide;
  String? guideError;
  int guideRevision = 0;
  int conversationEpoch = 0;
  final coachPanelKey = GlobalKey();
  final coachVideoKey = GlobalKey();
  bool savedAnalysisPending = false;
  List<List<double>> candidates = [];
  List<double>? selected;
  int selectionFrame = 0;
  String stroke = 'clear', arm = 'right';
  String? courtType, formatSuggestion, formatDetail;
  final List<Corner> courtCorners = [];
  bool detectingCourt = false, suggestingFormat = false;
  String? courtMessage;
  String? error;
  bool busy = false;
  final attempts = TextEditingController();
  Timer? timer;
  Player? player;
  VideoController? videoController;
  bool eventsDirty = false;
  bool loadingReport = false;
  bool controlBusy = false;
  WebSocketChannel? watchSocket;
  StreamSubscription? watchSubscription;
  Timer? watchTimer, watchClockTimer;
  final watchClock = Stopwatch();
  final frameClock = Stopwatch();
  bool watchActive = false, watchPlaying = false, watchWaiting = false, watchStopping = false;
  int watchFrame = -1, watchTotal = 0;
  double watchFps = 30, watchWidth = 1, watchHeight = 1;
  Map<String, dynamic> watchFrameData = {};
  List<int>? watchImage;
  String watchStatus = 'Connecting...';

  @override
  void initState() {
    super.initState();
    if (widget.jobId != null) Future.microtask(() => loadJob(widget.jobId!));
  }

  @override
  void dispose() {
    timer?.cancel();
    watchTimer?.cancel();
    watchClockTimer?.cancel();
    if (watchActive && !watchStopping) watchSocket?.sink.add(jsonEncode({'type': 'stop'}));
    unawaited(watchSubscription?.cancel());
    unawaited(watchSocket?.sink.close());
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
        guide = null;
        guideError = null;
        guideRevision++;
        eventsDirty = false;
        savedAnalysisPending = false;
        loadingReport = false;
        selectionFrame = 0;
        courtCorners.clear();
        courtMessage = null;
        courtType = null;
        formatSuggestion = null;
        formatDetail = null;
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

  Future<void> detectCourt() async {
    final info = video;
    if (info == null || detectingCourt) return;
    setState(() {
      detectingCourt = true;
      courtMessage = null;
    });
    try {
      final singles = await ref
          .read(apiClientProvider)
          .suggestCourtCorners(info.id, selectionFrame);
      final full = singles == null ? null : singlesToFull(singles);
      if (!mounted || video?.id != info.id) return;
      setState(() {
        if (full == null ||
            full.any((c) => c.x < 0 || c.y < 0 || c.x > info.width || c.y > info.height)) {
          courtMessage = 'Could not find the court. Mark the four corners manually.';
        } else {
          courtCorners
            ..clear()
            ..addAll(full);
          formatSuggestion = null;
          formatDetail = null;
          courtMessage = 'Check the suggested corners and drag them to adjust.';
        }
      });
    } catch (e) {
      if (mounted) setState(() => courtMessage = 'Could not find the court: $e');
    } finally {
      if (mounted) setState(() => detectingCourt = false);
    }
  }

  Future<void> suggestFormat() async {
    final info = video;
    final corners = fullToSingles(courtCorners);
    if (info == null || corners == null || suggestingFormat) return;
    setState(() {
      suggestingFormat = true;
      formatSuggestion = null;
      formatDetail = null;
    });
    try {
      final response = await ref.read(apiClientProvider).suggestMatchType(info.id, corners);
      if (!mounted || video?.id != info.id) return;
      setState(() {
        formatSuggestion = response['suggestion'] as String?;
        formatDetail = response['detail'] as String?;
      });
    } catch (e) {
      if (mounted) setState(() => formatDetail = 'Could not suggest a format: $e');
    } finally {
      if (mounted) setState(() => suggestingFormat = false);
    }
  }

  Future<void> start() async {
    final times = attempts.text.trim().isEmpty
        ? <double?>[]
        : attempts.text.split(',').map((s) => double.tryParse(s.trim())).toList();
    final singlesCorners = fullToSingles(courtCorners);
    if (courtType == null) {
      setState(() => error = 'Choose singles or doubles to match the video.');
      return;
    }
    if (singlesCorners == null) {
      setState(() => error = 'Mark the four court corners to use Watch player tracking.');
      return;
    }
    if (selected == null || times.any((v) => v == null || !v.isFinite)) {
      setState(() => error = 'Select a player and enter valid attempt times in seconds.');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final health = await ref.read(apiClientProvider).health();
      if (!health.practiceCourtWatch) {
        throw Exception(
          'This backend needs to be updated and restarted to support AI Coach playback.',
        );
      }
      final base = ref.read(apiClientProvider).liveUri();
      final uri = base.replace(path: base.path.replaceFirst(RegExp(r'/live$'), '/watch'));
      final channel = widget.channelFactory?.call(uri) ?? WebSocketChannel.connect(uri);
      watchSocket = channel;
      await channel.ready;
      if (!mounted) {
        await channel.sink.close();
        return;
      }
      setState(() {
        watchActive = true;
        watchPlaying = true;
        watchStopping = false;
        watchStatus = 'Connecting...';
      });
      watchClock
        ..reset()
        ..start();
      watchClockTimer?.cancel();
      watchClockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted && watchActive) setState(() {});
      });
      watchSubscription = channel.stream.listen(
        onWatchMessage,
        onError: (Object e) => watchFailure('Connection lost: $e'),
        onDone: () {
          if (mounted && watchActive) {
            watchFailure('Connection lost. Check History for the saved portion.');
          }
        },
      );
      channel.sink.add(
        jsonEncode({
          'type': 'start',
          'video_id': video!.id,
          'court': courtType!,
          'corners': [
            for (final c in singlesCorners) [c.x, c.y],
          ],
          'playback': 'complete',
          'mode': 'practice',
          'practice_setup': {
            'video_id': video!.id,
            'stroke': stroke,
            'arm': arm,
            'attempt_seconds': times,
            'selection_frame': selectionFrame,
            'selected_bbox': selected,
          },
        }),
      );
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void requestWatchFrame() {
    if (!mounted || !watchActive || !watchPlaying || watchWaiting || watchStopping) return;
    setState(() {
      watchWaiting = true;
      watchStatus = 'Catching up...';
    });
    frameClock
      ..reset()
      ..start();
    watchSocket?.sink.add(jsonEncode({'type': 'next'}));
  }

  void onWatchMessage(dynamic raw) {
    if (!mounted || raw is! String) return;
    final msg = jsonDecode(raw) as Map<String, dynamic>;
    switch (msg['type']) {
      case 'started':
        setState(() {
          watchFps = (msg['fps'] as num).toDouble();
          watchWidth = (msg['width'] as num).toDouble();
          watchHeight = (msg['height'] as num).toDouble();
          watchTotal = msg['frames'] as int;
        });
        requestWatchFrame();
      case 'video_frame':
        frameClock.stop();
        setState(() {
          watchImage = base64Decode(msg['jpeg'] as String);
          watchFrame = msg['index'] as int;
          watchWaiting = false;
          watchStatus = watchStopping
              ? 'Saving...'
              : watchPlaying
              ? 'Playing'
              : 'Paused';
          for (final event in (msg['events'] as List)) {
            if (event is Map<String, dynamic> && event['type'] == 'frame') watchFrameData = event;
          }
        });
        if (watchPlaying && !watchStopping) {
          watchTimer = Timer(watchFrameDelay(watchFps, frameClock.elapsed), requestWatchFrame);
        }
      case 'saved':
        final id = msg['job_id'] as String?;
        watchClock.stop();
        watchClockTimer?.cancel();
        setState(() {
          watchActive = false;
          watchPlaying = false;
        });
        ref.invalidate(jobsListProvider);
        if (id == null) {
          setState(() => error = 'No frames were analyzed, so no session was saved.');
        } else {
          video = null;
          unawaited(loadJob(id));
        }
      case 'error':
        watchFailure((msg['detail'] ?? 'Video analysis failed').toString());
    }
  }

  void watchFailure(String message) {
    watchTimer?.cancel();
    watchClock.stop();
    watchClockTimer?.cancel();
    if (mounted) {
      setState(() {
        watchActive = false;
        error = message;
      });
    }
  }

  void toggleWatch() {
    setState(() {
      watchPlaying = !watchPlaying;
      watchStatus = watchPlaying ? 'Playing' : 'Paused';
    });
    if (watchPlaying) requestWatchFrame();
  }

  void stopWatch() {
    if (watchFrame < 0 && !watchWaiting) {
      setState(() => error = 'No frames have been analyzed yet.');
      return;
    }
    watchTimer?.cancel();
    setState(() {
      watchStopping = true;
      watchPlaying = false;
      watchStatus = 'Saving...';
    });
    watchSocket?.sink.add(jsonEncode({'type': 'stop'}));
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
        final api = ref.read(apiClientProvider);
        final response = await api.practiceAnalysis(id);
        response.putIfAbsent('events', () => <dynamic>[]);
        if (!mounted) return;
        setState(() {
          result = response;
          error = null;
        });
        unawaited(loadGuide(id));
        final p = Player();
        final vc = VideoController(p);
        try {
          await p.open(Media(api.practiceVideoUrl(id), httpHeaders: api.authHeaders), play: false);
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
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  Future<void> loadGuide(String id, {bool refresh = false}) async {
    final revision = ++guideRevision;
    if (mounted) {
      setState(() {
        loadingReport = true;
        guideError = null;
      });
    }
    try {
      final report = await ref.read(apiClientProvider).practiceGuide(id, refresh: refresh);
      if (mounted && revision == guideRevision) setState(() => guide = report);
    } catch (e) {
      if (mounted && revision == guideRevision) setState(() => guideError = '$e');
    } finally {
      if (mounted && revision == guideRevision) setState(() => loadingReport = false);
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
      if (mounted) {
        setState(
          () => error = e is ApiException && e.statusCode == 404
              ? 'This session or its control endpoint is unavailable. Update and restart the backend, then check History.'
              : 'Could not update analysis: $e',
        );
      }
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
      final saved = await api.savePracticeEvents(id, result!['events'] as List);
      if (!mounted) return;
      setState(() => result = saved);
      await reloadSavedAnalysis(id);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> reloadSavedAnalysis(String id) async {
    ++guideRevision;
    setState(() {
      busy = true;
      error = null;
      eventsDirty = false;
      conversationEpoch++;
      savedAnalysisPending = true;
      loadingReport = false;
      guide = null;
      guideError = null;
    });
    try {
      final updated = await ref.read(apiClientProvider).practiceAnalysis(id);
      if (!mounted || job?['id'] != id) return;
      updated.putIfAbsent('events', () => <dynamic>[]);
      setState(() {
        result = updated;
        savedAnalysisPending = false;
      });
      unawaited(loadGuide(id));
    } catch (e) {
      if (mounted && job?['id'] == id) setState(() => guideError = '$e');
    } finally {
      if (mounted && job?['id'] == id) setState(() => busy = false);
    }
  }

  void seekCoachMoment(double seconds) {
    final playback = player;
    if (playback == null) return;
    unawaited(playback.seek(Duration(milliseconds: (seconds * 1000).round())));
    final videoContext = coachVideoKey.currentContext;
    if (videoContext != null) {
      unawaited(
        Scrollable.ensureVisible(
          videoContext,
          alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = video;
    final status = job?['status'] as String?;
    final selecting = info != null && !watchActive && (job == null || status == 'needs_selection');
    return PageScaffold(
      title: 'AI Coach',
      maxWidth: result == null ? 900 : 1200,
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
                      errorBuilder: (context, error, stack) =>
                          const Center(child: Text('Could not load the selection frame.')),
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
            const SizedBox(height: Spacing.lg),
            AppCard(
              title: 'Court calibration',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Mark the four outer court corners: near left, near right, far right, far left. AI Coach uses Watch player tracking.',
                  ),
                  const Text(
                    'Choose the format played in the video. Doubles tracks both players on each side.',
                  ),
                  DropdownButton<String>(
                    value: courtType,
                    hint: const Text('Choose singles or doubles'),
                    items: const [
                      DropdownMenuItem(value: 'singles', child: Text('Singles')),
                      DropdownMenuItem(value: 'doubles', child: Text('Doubles')),
                    ],
                    onChanged: busy || suggestingFormat
                        ? null
                        : (value) => setState(() => courtType = value),
                  ),
                  OutlinedButton(
                    onPressed: busy || detectingCourt ? null : detectCourt,
                    child: Text(detectingCourt ? 'Finding court...' : 'Find court automatically'),
                  ),
                  if (courtMessage != null) Text(courtMessage!),
                  OutlinedButton(
                    onPressed:
                        busy ||
                            detectingCourt ||
                            suggestingFormat ||
                            fullToSingles(courtCorners) == null
                        ? null
                        : suggestFormat,
                    child: Text(suggestingFormat ? 'Checking video...' : 'Suggest match format'),
                  ),
                  if (formatSuggestion != null)
                    Text('Suggested: $formatSuggestion. Choose and confirm the format above.'),
                  if (formatDetail != null) Text(formatDetail!),
                  SizedBox(
                    height: 320,
                    child: CornerCanvas(
                      image: NetworkImage(
                        ref.read(apiClientProvider).frameUrl(info.id, selectionFrame),
                      ),
                      width: info.width,
                      height: info.height,
                      corners: courtCorners,
                      overlayPainter: fullToSingles(courtCorners) == null
                          ? null
                          : (scale) => FullCourtPreview(courtCorners, scale),
                      onTap: (c) {
                        if (!busy && !suggestingFormat && courtCorners.length < 4) {
                          setState(() {
                            courtCorners.add(c);
                            formatSuggestion = null;
                            formatDetail = null;
                          });
                        }
                      },
                      onMove: (i, c) {
                        if (!busy && !suggestingFormat) {
                          setState(() {
                            courtCorners[i] = c;
                            formatSuggestion = null;
                            formatDetail = null;
                          });
                        }
                      },
                    ),
                  ),
                  TextButton(
                    onPressed: courtCorners.isEmpty || suggestingFormat
                        ? null
                        : () => setState(() {
                            courtCorners.clear();
                            formatSuggestion = null;
                            formatDetail = null;
                          }),
                    child: const Text('Clear corners'),
                  ),
                ],
              ),
            ),
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
              onPressed:
                  busy ||
                      detectingCourt ||
                      suggestingFormat ||
                      courtType == null ||
                      selected == null ||
                      fullToSingles(courtCorners) == null
                  ? null
                  : start,
              child: const Text('Confirm and analyze'),
            ),
          ] else
            FilledButton(
              onPressed: busy || selected == null ? null : resume,
              child: const Text('Resume with selected player'),
            ),
        ],
        if (watchActive) ...[
          const SizedBox(height: Spacing.lg),
          if (watchImage != null)
            AppCard(
              padding: const EdgeInsets.all(Spacing.md),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(Radii.md),
                child: AspectRatio(
                  aspectRatio: watchWidth / watchHeight,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Image.memory(
                        Uint8List.fromList(watchImage!),
                        gaplessPlayback: true,
                        fit: BoxFit.fill,
                      ),
                      CustomPaint(
                        painter: WatchOverlay(
                          watchFrameData,
                          watchWidth.round(),
                          watchHeight.round(),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          const SizedBox(height: Spacing.lg),
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$watchStatus - ${((watchFrame + 1) / watchFps).toStringAsFixed(1)} s / ${(watchTotal / watchFps).toStringAsFixed(1)} s',
                ),
                Text('Elapsed: ${formatWatchElapsed(watchClock.elapsed)} (includes pauses)'),
                if (watchFrameData['selection_failed'] == true)
                  const Text(
                    'Selected player could not be matched. Stop and save, then check singles or doubles and the court corners.',
                  ),
                if (watchFrameData['selection_failed'] != true &&
                    watchFrameData['players'] is Map &&
                    watchFrameData['selected_visible'] == false &&
                    info != null &&
                    watchFrame / watchFps >= selectionFrame / info.fps)
                  const Text('Selected player uncertain or not visible; this frame is excluded.'),
              ],
            ),
          ),
          const SizedBox(height: Spacing.lg),
          Wrap(
            spacing: 8,
            children: [
              FilledButton(
                onPressed: watchStopping ? null : toggleWatch,
                child: Text(watchPlaying ? 'Pause' : 'Play'),
              ),
              OutlinedButton(
                onPressed: watchStopping ? null : stopWatch,
                child: const Text('Stop and save'),
              ),
            ],
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
                  ? 'Rendering video...'
                  : 'Catching up...';
              return AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: Spacing.xs,
                  children: [
                    Text(
                      '$label${frame == null ? '' : ' - ${(frame / info!.fps).toStringAsFixed(1)} s / ${(info.numFrames / info.fps).toStringAsFixed(1)} s'}',
                    ),
                    Text(
                      'Elapsed: ${formatWatchElapsed(elapsed.isNegative ? Duration.zero : elapsed)} (includes pauses)',
                    ),
                    LinearProgressIndicator(value: status == 'queued' ? null : progress),
                    Text('${(progress * 100).round()}% - ${rendering ? 'Rendering' : 'Analyzing'}'),
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
          const Text('Preparing video and player selection...'),
        ],
        if (status == 'failed') Text('Analysis failed: ${job?['error']}'),
        if (status == 'done' && result == null && error != null)
          OutlinedButton(
            onPressed: () => loadJob(job!['id'] as String),
            child: const Text('Retry analysis'),
          ),
        if (result != null) ...[
          const SizedBox(height: Spacing.lg),
          LayoutBuilder(
            builder: (context, constraints) {
              final videoView = KeyedSubtree(
                key: coachVideoKey,
                child: videoController == null
                    ? const AspectRatio(
                        aspectRatio: 16 / 9,
                        child: Center(child: Text('Opening rendered video...')),
                      )
                    : AspectRatio(
                        aspectRatio: info!.aspectRatio,
                        child: Video(controller: videoController!),
                      ),
              );
              final panel = CoachGuidePanel(
                key: coachPanelKey,
                report: guide,
                rulesReport: savedAnalysisPending
                    ? null
                    : result?['rules_report'] as Map<String, dynamic>?,
                unavailableObservations: [
                  for (final attempt in (result?['observations'] as List? ?? const []))
                    for (final item in (attempt['observations'] as List? ?? const []))
                      if (item is Map<String, dynamic> && item['status'] == 'unavailable') item,
                ],
                loading: loadingReport,
                error: guideError,
                stale: eventsDirty,
                savedAnalysisPending: savedAnalysisPending,
                conversationEpoch: conversationEpoch,
                canAsk:
                    ref.watch(healthProvider).valueOrNull?.chatAvailable ??
                    ['gemini', 'claude'].contains(guide?['generated_by']),
                onRetry: () => savedAnalysisPending
                    ? reloadSavedAnalysis(job!['id'] as String)
                    : loadGuide(job!['id'] as String, refresh: true),
                onReload: () => reloadSavedAnalysis(job!['id'] as String),
                onAsk: (question, version, history, cancel) => ref
                    .read(apiClientProvider)
                    .practiceChat(
                      job!['id'] as String,
                      question,
                      contextVersion: version,
                      history: history,
                      cancelToken: cancel,
                    ),
                onSeek: seekCoachMoment,
              );
              if (constraints.maxWidth >= 850) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 3, child: videoView),
                    const SizedBox(width: Spacing.lg),
                    Expanded(flex: 2, child: panel),
                  ],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  videoView,
                  const SizedBox(height: Spacing.lg),
                  panel,
                ],
              );
            },
          ),
        ],
        if (result != null) ...[
          if (result!.containsKey('selected_slot') && result!['selected_slot'] == null)
            const Text(
              'Watch could not match your selection to a player. Check the court corners and select a clearly visible frame.',
            ),
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
                onChanged: busy || savedAnalysisPending
                    ? null
                    : (value) => setState(() {
                        event['stroke'] = value;
                        event['confirmed'] = true;
                        eventsDirty = true;
                      }),
              ),
              leading: Checkbox(
                value: event['confirmed'] == true,
                onChanged: busy || savedAnalysisPending
                    ? null
                    : (value) => setState(() {
                        event['confirmed'] = value;
                        eventsDirty = true;
                      }),
              ),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Remove event',
                onPressed: busy || savedAnalysisPending
                    ? null
                    : () => setState(() {
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
                onPressed: busy || savedAnalysisPending
                    ? null
                    : () => setState(() {
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
        ],
        if (error != null)
          Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
      ],
    );
  }
}
