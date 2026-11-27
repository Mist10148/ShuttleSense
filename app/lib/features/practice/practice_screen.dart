import 'dart:async';
import 'dart:math' as math;
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
import '../../core/theme/app_theme.dart';
import '../../shared/widgets/data_display.dart';
import '../../shared/widgets/helper_text.dart';
import '../../shared/widgets/notice.dart';
import '../../shared/widgets/section_card.dart';
import '../../shared/widgets/tactile.dart';
import '../../ui/depth.dart';
import '../results/widgets/video_panel.dart';
import '../upload/upload_screen.dart' show VideoDropZone, VideoFileRow;
import '../watch/watch_screen.dart' show formatWatchElapsed, watchFrameDelay, WatchOverlay;
import '../mode/mode_screen.dart';
import 'coach_guide_panel.dart';
import '../coach_personality/personality_notifier.dart';
import '../../core/config/app_mode.dart';
import 'package:go_router/go_router.dart';
import '../../core/router/app_router.dart';
import '../../shared/widgets/smooth_scroll.dart';
import '../../shared/widgets/court_view_field.dart';
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
    final info = video;
    if (info == null) return;
    setState(() {
      busy = true;
      error = null;
      selected = null;
      candidates = [];
    });
    try {
      final api = ref.read(apiClientProvider);
      final analysisKind = (job?['practice_setup'] as Map?)?['analysis_kind'];
      final useWatchGrid = job != null
          ? analysisKind == 'general'
          : (ref.read(healthProvider).valueOrNull ?? await api.health()).practiceGeneral;
      if (!mounted || video?.id != info.id) return;
      final data = useWatchGrid
          ? await api.practiceWatchPlayers(info.id, selectionFrame)
          : await api.practicePlayers(info.id, selectionFrame);
      final values = (data['candidates'] as List)
          .map((p) => (p['bbox'] as List).map((n) => (n as num).toDouble()).toList())
          .toList();
      if (mounted && video?.id == info.id) {
        setState(() {
          selectionFrame = (data['frame'] as num?)?.toInt() ?? selectionFrame;
          candidates = values;
        });
      }
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

  Future<void> start({bool general = false}) async {
    final times = attempts.text.trim().isEmpty
        ? <double?>[]
        : attempts.text.split(',').map((s) => double.tryParse(s.trim())).toList();
    final singlesCorners = fullToSingles(courtCorners);
    if (!general && courtType == null) {
      setState(() => error = 'Choose singles or doubles to match the video.');
      return;
    }
    if (!general && singlesCorners == null) {
      setState(() => error = 'Mark the four court corners to use Watch player tracking.');
      return;
    }
    if (selected == null || times.any((v) => v == null || !v.isFinite)) {
      setState(() => error = 'Select a player and enter valid review times in seconds.');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final api = ref.read(apiClientProvider);
      final health = await api.health();
      if (!mounted) return;
      if (general) {
        if (!health.practiceGeneral) {
          throw Exception('General practice is unavailable on this backend.');
        }
        final queued = await api.startPractice({
          'analysis_kind': 'general',
          'video_id': video!.id,
          'selection_frame': selectionFrame,
          'selected_bbox': selected,
          'review_seconds': times,
        });
        if (mounted) {
          setState(() => job = queued);
          await loadJob(queued['id'] as String);
        }
        return;
      }
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
            for (final c in singlesCorners!) [c.x, c.y],
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
        final generalPreview =
            status == 'running' &&
            (data['practice_setup'] as Map?)?['analysis_kind'] == 'general' &&
            data['preview'] != null &&
            data['current_stage'] != 'render';
        timer = Timer(
          generalPreview ? const Duration(milliseconds: 300) : const Duration(seconds: 1),
          () => loadJob(id),
        );
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

  void analyzeAgain() {
    final playback = player;
    ++guideRevision;
    attempts.clear();
    setState(() {
      job = result = guide = null;
      guideError = error = null;
      loadingReport = eventsDirty = savedAnalysisPending = false;
      player = null;
      videoController = null;
      selected = null;
      candidates = [];
    });
    unawaited(playback?.dispose());
    unawaited(findPlayers());
  }

  /// An analysis is under way (live watch or a queued/running job): the video stays.
  bool _running(String? status) => watchActive || status == 'queued' || status == 'running';

  /// Starts over on a new video: a fresh AI Coach screen. Past sessions stay in History.
  Future<void> newVideo() async {
    ref.read(practiceSessionProvider.notifier).next();
    // From a saved session (opened from History) the Analyze tab may be on another mode.
    await ref.read(appModeProvider.notifier).set(AppMode.practice);
    if (mounted && widget.jobId != null) context.go(Routes.home);
  }

  @override
  Widget build(BuildContext context) {
    final info = video;
    final status = job?['status'] as String?;
    final generalAvailable = ref.watch(healthProvider).valueOrNull?.practiceGeneral ?? false;
    final generalResult = result?['analysis_kind'] == 'general';
    final generalJob = (job?['practice_setup'] as Map?)?['analysis_kind'] == 'general';
    final legacyReselect = status == 'needs_selection' && !generalJob;
    final selecting = info != null && !watchActive && (job == null || status == 'needs_selection');
    final p = AppPalette.of(context);
    // A framed picture: the frame to pick from, the live preview, the result video.
    Widget framed(Widget child) => AppCard(
      padding: const EdgeInsets.all(Spacing.md),
      child: ClipRRect(borderRadius: BorderRadius.circular(Radii.md), child: child),
    );
    // One numbered step of the setup, the same card as New analysis.
    Widget step(String title, List<Widget> children) => Padding(
      padding: const EdgeInsets.only(top: Spacing.lg),
      child: SectionCard(
        title: title,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: Spacing.md,
          children: children,
        ),
      ),
    );
    final intro = generalAvailable && job == null
        ? 'Use a steady, well-lit camera. Keep your whole body and racket arm in frame '
              'throughout the movement. Select yourself on a clear frame before your first stroke.'
        : !generalResult && !generalJob
        ? 'Recorded practice for clear, smash or drop. Marked attempts are not verified shuttle contacts.'
        : null;
    // The review cards (stroke events or moments) for a finished session.
    List<Widget> reviewCards() => [
      if (generalResult) ...[
        const SizedBox(height: Spacing.lg),
        _generalReview(result!, generalAvailable),
      ] else if (result != null) ...[
        const SizedBox(height: Spacing.lg),
        SectionCard(
          title: 'Review stroke events',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: Spacing.sm,
            children: [
              if (result!.containsKey('selected_slot') && result!['selected_slot'] == null)
                const HelperText(
                  'Watch could not match your selection to a player. Check the court corners and select a clearly visible frame.',
                  warning: true,
                ),
              if (result!['stopped_early'] == true)
                const HelperText(
                  'This session was stopped early; the video and report cover the analyzed portion.',
                ),
              const HelperText(
                'Automatic predictions are estimates. Confirm, correct or remove them before updating the report.',
              ),
              const HelperText('Detailed pose observations currently cover clear, smash and drop.'),
              if (result!['shuttle_tracking_available'] != true)
                const HelperText(
                  'Shuttle tracking was unavailable; automatic stroke detection may be incomplete.',
                  warning: true,
                ),
              for (final event in ((result!['events'] as List?) ?? []))
                _EventRow(
                  event: event as Map<String, dynamic>,
                  enabled: !(busy || savedAnalysisPending),
                  onStroke: (value) => setState(() {
                    event['stroke'] = value;
                    event['confirmed'] = true;
                    eventsDirty = true;
                  }),
                  onConfirmed: (value) => setState(() {
                    event['confirmed'] = value;
                    eventsDirty = true;
                  }),
                  onRemove: () => setState(() {
                    (result!['events'] as List).remove(event);
                    eventsDirty = true;
                  }),
                  onSeek: () => player?.seek(
                    Duration(milliseconds: ((event['time_s'] as num) * 1000).round()),
                  ),
                ),
              Wrap(
                spacing: Spacing.sm,
                runSpacing: Spacing.sm,
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
              if (eventsDirty)
                const HelperText(
                  'Unsaved event changes are not included in the report.',
                  warning: true,
                ),
              if ((result!['unobserved_frames'] as num? ?? 0) > 0)
                const HelperText(
                  'The selected player was not confidently tracked in some frames; those moments are excluded from player analysis.',
                ),
            ],
          ),
        ),
      ],
    ];
    return PageScaffold(
      title: 'AI Coach',
      // One width throughout, so the page does not jump when the report arrives.
      maxWidth: 1100,
      actions: [
        if (info != null && !_running(status))
          TextButton.icon(
            onPressed: busy ? null : newVideo,
            icon: const Icon(Icons.add_rounded),
            label: const Text('New video'),
          ),
        const ChangeModeButton(),
      ],
      children: [
        if (intro != null)
          Text(intro, style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: p.text2)),
        const SizedBox(height: Spacing.lg),
        // Step 1, the same card as New analysis' "1. Rally video".
        SectionCard(
          title: '1. Practice video',
          child: info == null
              ? VideoDropZone(
                  title: 'Choose a practice video',
                  detail:
                      'One player, MP4, MOV or AVI. A steady camera with your whole body in '
                      'frame gives the clearest pose tracking.',
                  actions: [
                    FilledButton.tonalIcon(
                      onPressed: busy ? null : pick,
                      icon: const Icon(Icons.video_library_outlined),
                      label: const Text('Choose practice video'),
                    ),
                  ],
                )
              : VideoFileRow(
                  name: info.filename,
                  details:
                      '${(info.numFrames / info.fps).toStringAsFixed(1)} s · '
                      '${info.width}×${info.height} · ${info.fps.round()} fps',
                  warn: false,
                  actions: [
                    if (!_running(status))
                      OutlinedButton.icon(
                        onPressed: busy ? null : newVideo,
                        icon: const Icon(Icons.swap_horiz_rounded),
                        label: const Text('Change video'),
                      ),
                  ],
                ),
        ),
        if (selecting) ...[
          step('2. Select the player', [
            Text(
              status == 'needs_selection'
                  ? generalJob
                        ? 'The selected player could not be confirmed. Pick a clear frame and select yourself again.'
                        : 'Select the player to continue this older session.'
                  : 'Choose the player in the frame.',
            ),
            Slider(
              min: legacyReselect ? (job!['practice_selection_frame'] as int).toDouble() : 0,
              value: selectionFrame.toDouble(),
              max: (info.numFrames - 1)
                  .clamp(
                    legacyReselect ? (job!['practice_selection_frame'] as int) + 1 : 1,
                    10000000,
                  )
                  .toDouble(),
              onChanged:
                  busy ||
                      info.numFrames <= 1 ||
                      (legacyReselect &&
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
                label: Text(
                  generalAvailable ? 'Mark this moment for review' : 'Mark attempt at this frame',
                ),
              ),
              Text(
                generalAvailable
                    ? 'Select the player at or before the first marked moment.'
                    : 'Select the player at or before the first marked attempt.',
              ),
            ] else
              const Text(
                'Move forward if the player is hidden; skipped attempts will be unavailable.',
              ),
            framed(
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
                          ref
                              .read(apiClientProvider)
                              .frameUrl(info.id, selectionFrame, maxWidth: 3840),
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
                                    // Chosen in the "in" green, the others in the review amber.
                                    color: identical(box, selected)
                                        ? StatusColors.of(context).inCall
                                        : StatusColors.of(context).uncertain,
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
            ),
            if (candidates.isEmpty && !busy)
              const HelperText(
                'No player detected. Choose another frame or check the models.',
                warning: true,
              ),
            if (job != null)
              FilledButton(
                onPressed: busy || selected == null ? null : resume,
                child: const Text('Resume with selected player'),
              ),
          ]),
          if (job == null) ...[
            if (!generalAvailable) ...[
              Padding(
                padding: const EdgeInsets.only(top: Spacing.lg),
                child: AppCard(
                  title: '3. Court calibration',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    spacing: Spacing.md,
                    children: [
                      const CourtViewField(),
                      Text(
                        'Mark the four outer court corners: '
                        '${cornerOrderFor(ref.watch(courtViewProvider))}. AI Coach uses Watch '
                        'player tracking.',
                      ),
                      const Text(
                        'Choose the format played in the video. Doubles tracks both players on each side.',
                      ),
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: DepthSegmented<String>(
                          segments: const [
                            ButtonSegment(value: 'singles', label: Text('Singles')),
                            ButtonSegment(value: 'doubles', label: Text('Doubles')),
                          ],
                          selected: {?courtType},
                          emptySelectionAllowed: true,
                          onSelectionChanged: busy || suggestingFormat
                              ? null
                              : (value) => setState(
                                  () => courtType = value.isEmpty ? courtType : value.first,
                                ),
                        ),
                      ),
                      if (courtType == null) const HelperText('Choose singles or doubles'),
                      Wrap(
                        spacing: Spacing.sm,
                        runSpacing: Spacing.sm,
                        children: [
                          OutlinedButton(
                            onPressed: busy || detectingCourt ? null : detectCourt,
                            child: Text(
                              detectingCourt ? 'Finding court…' : 'Find court automatically',
                            ),
                          ),
                          OutlinedButton(
                            onPressed:
                                busy ||
                                    detectingCourt ||
                                    suggestingFormat ||
                                    fullToSingles(courtCorners) == null
                                ? null
                                : suggestFormat,
                            child: Text(
                              suggestingFormat ? 'Checking video…' : 'Suggest match format',
                            ),
                          ),
                        ],
                      ),
                      if (courtMessage != null) HelperText(courtMessage!),
                      if (formatSuggestion != null)
                        HelperText(
                          'Suggested: $formatSuggestion. Choose and confirm the format above.',
                        ),
                      if (formatDetail != null) HelperText(formatDetail!),
                      // The frame at its own shape and the full width: no empty margins.
                      SizedBox(
                        child: CornerCanvas(
                          cornerNames: cornerNamesFor(ref.watch(courtViewProvider)),
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
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: TextButton(
                          onPressed: courtCorners.isEmpty || suggestingFormat
                              ? null
                              : () => setState(() {
                                  courtCorners.clear();
                                  formatSuggestion = null;
                                  formatDetail = null;
                                }),
                          child: const Text('Clear corners'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            step(generalAvailable ? '3. Review times' : '4. Stroke and options', [
              if (!generalAvailable) ...[
                Wrap(
                  spacing: Spacing.lg,
                  runSpacing: Spacing.md,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      spacing: Spacing.xs,
                      children: [
                        Text('Stroke', style: Theme.of(context).textTheme.titleSmall),
                        DepthSegmented<String>(
                          segments: const [
                            ButtonSegment(value: 'clear', label: Text('Clear')),
                            ButtonSegment(value: 'smash', label: Text('Smash')),
                            ButtonSegment(value: 'drop', label: Text('Drop')),
                          ],
                          selected: {stroke},
                          onSelectionChanged: (s) => setState(() => stroke = s.first),
                        ),
                      ],
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      spacing: Spacing.xs,
                      children: [
                        Text('Racket arm', style: Theme.of(context).textTheme.titleSmall),
                        DepthSegmented<String>(
                          segments: const [
                            ButtonSegment(value: 'right', label: Text('Right')),
                            ButtonSegment(value: 'left', label: Text('Left')),
                          ],
                          selected: {arm},
                          onSelectionChanged: (s) => setState(() => arm = s.first),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
              TextField(
                controller: attempts,
                decoration: InputDecoration(
                  labelText: generalAvailable
                      ? 'Review times (optional)'
                      : 'Attempt times (optional)',
                  hintText: '1.2, 3.5, 6.0',
                  helperText: 'In seconds, separated by commas',
                ),
              ),
              FilledButton(
                onPressed:
                    busy ||
                        detectingCourt ||
                        suggestingFormat ||
                        selected == null ||
                        (!generalAvailable &&
                            (courtType == null || fullToSingles(courtCorners) == null))
                    ? null
                    : () => start(general: generalAvailable),
                child: const Text('Confirm and analyze'),
              ),
            ]),
          ],
        ],
        if (watchActive) ...[
          const SizedBox(height: Spacing.lg),
          if (watchImage != null)
            framed(
              AspectRatio(
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
          const SizedBox(height: Spacing.lg),
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: Spacing.xs,
              children: [
                Text(
                  '$watchStatus - ${((watchFrame + 1) / watchFps).toStringAsFixed(1)} s / ${(watchTotal / watchFps).toStringAsFixed(1)} s',
                ),
                Text('Elapsed: ${formatWatchElapsed(watchClock.elapsed)} (includes pauses)'),
                if (watchFrameData['selection_failed'] == true)
                  const HelperText(
                    'Selected player could not be matched. Stop and save, then check singles or doubles and the court corners.',
                    warning: true,
                  ),
                if (watchFrameData['selection_failed'] != true &&
                    watchFrameData['players'] is Map &&
                    watchFrameData['selected_visible'] == false &&
                    info != null &&
                    watchFrame / watchFps >= selectionFrame / info.fps)
                  const HelperText(
                    'Selected player uncertain or not visible; this frame is excluded.',
                    warning: true,
                  ),
              ],
            ),
          ),
          const SizedBox(height: Spacing.lg),
          Wrap(
            spacing: Spacing.sm,
            runSpacing: Spacing.sm,
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
            framed(
              AspectRatio(
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
                  ? 'Saving session…'
                  : paused
                  ? 'Paused'
                  : rendering
                  ? 'Rendering video…'
                  : 'Catching up…';
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
                    const SizedBox(height: Spacing.xs),
                    if (status == 'queued')
                      const LinearProgressIndicator()
                    else
                      GradientProgress(
                        value: progress,
                        label:
                            '${(progress * 100).round()}% · ${rendering ? 'Rendering' : 'Analyzing'}',
                      ),
                    const HelperText('The preview shows the latest analyzed frame.'),
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
                  spacing: Spacing.sm,
                  runSpacing: Spacing.sm,
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
          Row(
            children: [
              SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: TactileTokens.of(context).primary,
                ),
              ),
              const SizedBox(width: Spacing.sm),
              const Flexible(child: Text('Preparing video and player selection…')),
            ],
          ),
          const SizedBox(height: Spacing.sm),
          const Skeleton(height: 220, width: double.infinity),
        ],
        if (status == 'failed')
          Padding(
            padding: const EdgeInsets.only(top: Spacing.lg),
            child: NoticeBanner(
              tone: NoticeTone.error,
              title: 'Analysis failed',
              message: '${job?['error'] ?? 'The analysis stopped with an error.'}',
            ),
          ),
        if (status == 'done' && result == null && error != null)
          OutlinedButton(
            onPressed: () => loadJob(job!['id'] as String),
            child: const Text('Retry analysis'),
          ),
        if (result != null) ...[
          const SizedBox(height: Spacing.lg),
          LayoutBuilder(
            builder: (context, constraints) {
              // The rendered video in the same frame and player as Results; its own controls
              // are plain white icons there, not the app's raised keys.
              final videoView = KeyedSubtree(
                key: coachVideoKey,
                child: framed(
                  videoController == null
                      ? const AspectRatio(
                          aspectRatio: 16 / 9,
                          child: ColoredBox(
                            color: Colors.black,
                            child: Center(
                              child: Text(
                                'Opening rendered video...',
                                style: TextStyle(color: Colors.white70),
                              ),
                            ),
                          ),
                        )
                      : VideoPanel(
                          controller: videoController,
                          available: true,
                          aspectRatio: info!.aspectRatio,
                        ),
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
                      personality: ref.read(activePersonalityRequestProvider),
                    ),
                onSeek: seekCoachMoment,
              );
              // Wide: two equal columns, the video with its review cards under it on the left
              // and the coach on the right, so neither side is left half empty.
              if (constraints.maxWidth >= 980) {
                // A two-pane workspace the height of the window: each side scrolls on its own,
                // so the shorter one never leaves an empty strip beside the longer one.
                final paneHeight = math.max(560.0, MediaQuery.sizeOf(context).height - 150);
                Widget pane(List<Widget> children) => SmoothScroll(
                  builder: (context, controller) => SingleChildScrollView(
                    controller: controller,
                    // Room for the cards' shadows inside the scroll area.
                    padding: const EdgeInsets.fromLTRB(4, 4, 12, Spacing.lg),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: children,
                    ),
                  ),
                );
                return SizedBox(
                  height: paneHeight,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: pane([videoView, ...reviewCards()])),
                      const SizedBox(width: Spacing.sm),
                      // The coach card runs the full height of its pane, top-aligned content.
                      Expanded(
                        child: pane([
                          ConstrainedBox(
                            constraints: BoxConstraints(minHeight: paneHeight - 4 - Spacing.lg),
                            child: panel,
                          ),
                        ]),
                      ),
                    ],
                  ),
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  videoView,
                  const SizedBox(height: Spacing.lg),
                  panel,
                  ...reviewCards(),
                ],
              );
            },
          ),
        ],
        if (error != null) HelperText(error!, error: true),
      ],
    );
  }

  Widget _generalReview(Map<String, dynamic> analysis, bool canRetry) {
    final selectedFrom = (analysis['selection_frame'] as int?) ?? 0;
    final frames = (analysis['processed_frames'] as int?) ?? 0;
    final untracked = (analysis['unobserved_frames'] as int?) ?? 0;
    final tracked = frames - selectedFrom - untracked;
    final lost = analysis['tracking_lost_from_s'];
    return AppCard(
      title: 'Review moments',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: Spacing.sm,
        children: [
          Text('Tracked $tracked of ${frames - selectedFrom} frames after selection.'),
          if (analysis['stopped_early'] == true)
            const HelperText('This report covers the saved portion of the video.'),
          if (lost is num) ...[
            HelperText(
              'The selected player could not be confidently recovered from ${lost.toStringAsFixed(1)} s.',
              warning: true,
            ),
            if (canRetry) TextButton(onPressed: analyzeAgain, child: const Text('Analyze again')),
          ],
          for (final moment in (analysis['review_moments'] as List? ?? const []))
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: IconWell(
                icon: switch (moment['kind']) {
                  'marked' => Icons.bookmark_outline_rounded,
                  'movement' => Icons.directions_run_rounded,
                  _ => Icons.photo_camera_outlined,
                },
                size: 36,
                iconSize: 18,
              ),
              trailing: TimePill(
                label: formatMinSec(moment['time_s'] as num),
                onTap: () => seekCoachMoment((moment['time_s'] as num).toDouble()),
              ),
              title: Text(switch (moment['kind']) {
                'marked' => 'Marked moment',
                'movement' => 'Movement to review',
                _ => 'Pose snapshot',
              }),
              subtitle: Text(
                '${(moment['time_s'] as num).toStringAsFixed(1)} s'
                '${(moment['observations'] as List).any((o) => o['status'] == 'observed') ? '' : ' · Pose unavailable'}',
              ),
              onTap: () => seekCoachMoment((moment['time_s'] as num).toDouble()),
            ),
        ],
      ),
    );
  }
}

/// One stroke event to review: a recessed confirm box, the time and where the label came
/// from, the stroke in a recessed picker, and remove. A confirmed event gets an accent edge
/// and a soft tint across the whole rounded row.
class _EventRow extends StatelessWidget {
  const _EventRow({
    required this.event,
    required this.enabled,
    required this.onStroke,
    required this.onConfirmed,
    required this.onRemove,
    required this.onSeek,
  });

  final Map<String, dynamic> event;
  final bool enabled;
  final ValueChanged<String?> onStroke;
  final ValueChanged<bool> onConfirmed;
  final VoidCallback onRemove;
  final VoidCallback onSeek;

  static const _strokes = ['clear', 'smash', 'drop', 'net_shot', 'lift', 'serve'];

  static String _label(String s) => (s[0].toUpperCase() + s.substring(1)).replaceAll('_', ' ');

  @override
  Widget build(BuildContext context) {
    final t = TactileTokens.of(context);
    final p = AppPalette.of(context);
    final text = Theme.of(context).textTheme;
    final confirmed = event['confirmed'] == true;
    final manual = event['source'] == 'manual';
    final accent = manual ? StatusColors.of(context).inCall : t.primary;
    final time = (event['time_s'] as num).toDouble();
    final meta = [
      '${event['source']}',
      '${event['model'] ?? 'user label'}',
      if (event['confidence'] case final num c) '${(c * 100).toStringAsFixed(0)}% confidence',
    ].join(' · ');
    const radius = BorderRadius.all(Radius.circular(Radii.md));
    final picker = InsetBox(
      radius: 10,
      padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: event['stroke'] as String?,
          isExpanded: true,
          isDense: true,
          borderRadius: BorderRadius.circular(Radii.md),
          padding: const EdgeInsets.symmetric(vertical: Spacing.sm + 2),
          hint: const Text('Choose stroke'),
          items: [for (final s in _strokes) DropdownMenuItem(value: s, child: Text(_label(s)))],
          onChanged: enabled ? onStroke : null,
        ),
      ),
    );
    final when = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '${time.toStringAsFixed(1)} s',
          style: kFigureStyle.copyWith(fontSize: 18, color: p.ink, letterSpacing: 0),
        ),
        Text(
          meta,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: text.bodySmall?.copyWith(color: p.text3, height: 1.3),
        ),
      ],
    );
    final remove = Theme(
      // A flat icon, not a raised key: it is a secondary action on every row.
      data: Theme.of(context).copyWith(iconButtonTheme: const IconButtonThemeData()),
      child: IconButton(
        icon: const Icon(Icons.delete_outline_rounded),
        color: p.text3,
        hoverColor: Theme.of(context).colorScheme.error.withValues(alpha: 0.08),
        tooltip: 'Remove event',
        onPressed: enabled ? onRemove : null,
      ),
    );
    final check = DepthCheckbox(
      value: confirmed,
      label: 'Confirmed',
      onChanged: enabled ? onConfirmed : null,
    );
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      decoration: BoxDecoration(
        borderRadius: radius,
        // Confirmed rows carry a faint tint and a coloured outline; others a fine edge.
        color: confirmed ? accent.withValues(alpha: 0.06) : t.raisedTop.withValues(alpha: 0.5),
        border: Border.all(
          color: confirmed ? accent.withValues(alpha: 0.35) : (p.hairline ?? p.surface2),
        ),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          // The whole row, rounded, plays the video from this event.
          borderRadius: radius,
          onTap: onSeek,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Spacing.xs, Spacing.sm, Spacing.xs, Spacing.sm),
            child: LayoutBuilder(
              builder: (context, box) {
                if (box.maxWidth >= 440) {
                  return Row(
                    children: [
                      check,
                      const SizedBox(width: Spacing.xs),
                      SizedBox(width: 150, child: when),
                      const SizedBox(width: Spacing.md),
                      Expanded(child: picker),
                      const SizedBox(width: Spacing.xs),
                      remove,
                    ],
                  );
                }
                // Narrow: the time row on top, the picker under it.
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        check,
                        const SizedBox(width: Spacing.xs),
                        Expanded(child: when),
                        remove,
                      ],
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(Spacing.sm, Spacing.xs, Spacing.sm, 0),
                      child: picker,
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
