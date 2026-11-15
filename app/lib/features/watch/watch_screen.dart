import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../core/router/app_router.dart';
import '../../data/models/video_info.dart';
import '../../data/api_client.dart';
import '../../data/repositories/analysis_repository.dart';
import '../../shared/widgets/page_scaffold.dart';
import '../calibration/calibration_screen.dart';
import '../upload/upload_controller.dart';

class WatchScreen extends ConsumerStatefulWidget {
  const WatchScreen({super.key});
  @override
  ConsumerState<WatchScreen> createState() => _WatchScreenState();
}

class _WatchScreenState extends ConsumerState<WatchScreen> {
  VideoInfo? video;
  final List<Corner> corners = [];
  WebSocketChannel? socket;
  CancelToken? uploadCancel;
  StreamSubscription<dynamic>? subscription;
  Timer? timer;
  Timer? backgroundTimer;
  bool backgroundStarted = false, backgroundBusy = false;
  bool stopAcknowledged = false;
  ApiClient? backgroundApi;
  double analysisSeconds = 0;
  Player? player;
  VideoController? videoController;
  StreamSubscription<Duration>? videoPositionSubscription;
  StreamSubscription<bool>? videoCompletedSubscription;
  StreamSubscription<String>? videoErrorSubscription;
  Duration videoPosition = Duration.zero;
  int lastRequestedIndex = -1;
  int lastAnalyzedIndex = -1;
  bool realTime = true;
  final Stopwatch frameClock = Stopwatch();
  Uint8List? image;
  bool uploading = false, playing = false, waiting = false, stopping = false, started = false;
  String? error, jobId;
  String status = 'Choose a recorded video to begin.';
  double fps = 30;
  int index = 0, total = 0;
  String rally = 'Waiting', latestHit = '', score = '', coaching = '', lineCall = '';
  Map<String, dynamic>? frameData;
  String? pendingFrame;
  int frameWidth = 1, frameHeight = 1;
  bool synthetic = false;
  bool modelsMissing = false;
  bool autoMode = false, scanning = false;
  String? matchType, suggestion;
  String? suggestionDetail;

  Future<void> suggest() async {
    final info = video;
    if (info == null || !isConvex(corners) || scanning) return;
    setState(() {
      scanning = true;
      matchType = null;
      suggestion = null;
      suggestionDetail = null;
      error = null;
    });
    try {
      final result = await ref.read(apiClientProvider).suggestMatchType(info.id, List.of(corners));
      if (!mounted) return;
      setState(() {
        suggestion = result['suggestion'] as String?;
        suggestionDetail = result['detail'] as String?;
      });
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => scanning = false);
    }
  }

  Future<void> pick() async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['mp4', 'mov', 'avi'],
    );
    if (files.isEmpty || !mounted) return;
    final file = files.first;
    final size = await file.length();
    final problem = uploadSizeProblem(size, web: kIsWeb);
    if (problem != null) {
      setState(() => error = problem);
      return;
    }
    setState(() {
      uploading = true;
      error = null;
    });
    final api = ref.read(apiClientProvider);
    final cancel = uploadCancel = CancelToken();
    try {
      final result = await api.uploadVideo(
        stream: file.readAsByteStream(),
        length: size!,
        filename: file.name,
        cancelToken: cancel,
      );
      if (!mounted) {
        unawaited(api.deleteVideo(result.id).catchError((Object _) {}));
        return;
      }
      setState(() {
        video = result;
        corners.clear();
        matchType = null;
        status = 'Tap the four singles court corners for player detection.';
      });
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (identical(uploadCancel, cancel)) uploadCancel = null;
      if (mounted) setState(() => uploading = false);
    }
  }

  Future<void> start() async {
    final info = video;
    if (info == null || socket != null || matchType == null) return;
    if (realTime) {
      await startBackground(info);
      return;
    }
    final base = ref.read(apiClientProvider).liveUri();
    final channel = WebSocketChannel.connect(
      base.replace(path: base.path.replaceFirst(RegExp(r'/live$'), '/watch')),
    );
    socket = channel;
    setState(() {
      status = 'Connecting…';
      error = null;
    });
    try {
      await channel.ready;
      if (!mounted) {
        await channel.sink.close();
        return;
      }
      subscription = channel.stream.listen(
        onMessage,
        onError: (Object e) => fail('Connection lost: $e'),
        onDone: () {
          if (mounted && status != 'Session saved' && error == null) {
            fail('Connection lost. Check History for the analyzed portion.');
          }
        },
      );
      channel.sink.add(
        jsonEncode({
          'type': 'start',
          'video_id': info.id,
          'court': matchType,
          'playback': realTime ? 'realtime' : 'complete',
          if (isConvex(corners))
            'corners': [
              for (final c in corners) [c.x, c.y],
            ],
        }),
      );
    } catch (e) {
      fail('Could not connect: $e');
    }
  }

  Future<void> startBackground(VideoInfo info) async {
    setState(() {
      backgroundStarted = true;
      status = 'Starting analysis…';
      error = null;
    });
    try {
      final api = ref.read(apiClientProvider);
      backgroundApi = api;
      final result = await api.startBackgroundWatch(
        videoId: info.id,
        court: matchType!,
        corners: isConvex(corners) ? List.of(corners) : [],
      );
      if (!mounted) return;
      setState(() {
        jobId = result['job_id'] as String;
        fps = (result['fps'] as num).toDouble();
        total = result['frames'] as int;
        frameWidth = result['width'] as int;
        frameHeight = result['height'] as int;
        final stages = result['stages'] as Map?;
        synthetic = stages?['synthetic'] == true;
        modelsMissing = stages?['tracking'] == false || stages?['pose'] == false;
        started = true;
      });
      ref.invalidate(jobsListProvider);
      backgroundTimer = Timer.periodic(const Duration(seconds: 1), (_) => pollBackground());
      await startRealtimePlayer();
    } catch (e) {
      if (mounted) {
        setState(() {
          backgroundStarted = false;
          error = '$e';
        });
      }
    }
  }

  Future<void> pollBackground() async {
    final id = jobId;
    if (id == null || backgroundBusy || !mounted) return;
    backgroundBusy = true;
    try {
      final api = ref.read(apiClientProvider);
      final data = stopping
          ? await api.backgroundWatchStatus(id)
          : await api.updateBackgroundWatch(id, videoPosition.inMilliseconds / 1000);
      if (!mounted) return;
      setState(() {
        analysisSeconds = (data['analyzed_s'] as num?)?.toDouble() ?? 0;
        final frame = data['frame'];
        if (frame is Map<String, dynamic>) {
          frameData = frame;
          lastAnalyzedIndex = (frame['frame'] as num?)?.toInt() ?? -1;
          rally = (frame['rally_state'] ?? 'Waiting').toString().replaceAll('_', ' ');
        }
        for (final e in (data['events'] as List? ?? const [])) {
          if (e is! Map) continue;
          if (e['type'] == 'hit' && e['hit'] is Map) {
            final hit = e['hit'] as Map;
            latestHit = hit['stroke'] == null ? 'Unclassified hit' : 'Stroke: ${hit['stroke']}';
            if (hit['time_s'] is num) {
              latestHit += ' at ${(hit['time_s'] as num).toStringAsFixed(1)} s';
            }
          }
          if (e['type'] == 'score' && e['score'] is Map) {
            final s = e['score'] as Map;
            score = 'Score: ${s['near'] ?? 0} – ${s['far'] ?? 0}';
          }
          if (e['type'] == 'line_call' && e['line_call'] is Map) {
            final call = e['line_call'] as Map;
            lineCall =
                'Line call: ${call['call'] ?? 'unknown'}${call['uncertain'] == true ? ' (review)' : ''}';
            if (call['time_s'] is num) {
              lineCall += ' at ${(call['time_s'] as num).toStringAsFixed(1)} s';
            }
          }
          if (e['type'] == 'coaching' && e['coaching'] is Map) {
            final notes = (e['coaching'] as Map)['session_notes'];
            if (notes is List) {
              coaching = notes
                  .whereType<Map>()
                  .map((n) => n['text'])
                  .whereType<String>()
                  .take(3)
                  .join('\n');
            }
          }
        }
        if (data['status'] == 'done') {
          status = 'Session saved';
          stopping = true;
          backgroundTimer?.cancel();
        } else if (data['status'] == 'failed' || data['status'] == 'cancelled') {
          error = '${data['error'] ?? 'Analysis failed'}';
          stopping = true;
          backgroundTimer?.cancel();
        } else if (stopping) {
          status = !stopAcknowledged
              ? 'Confirming stop…'
              : data['stage'] == 'render'
              ? 'Rendering…'
              : 'Finishing analysis…';
        }
      });
      if (data['status'] == 'done' || data['status'] == 'failed') ref.invalidate(jobsListProvider);
    } catch (e) {
      if (mounted) setState(() => error = 'Could not update analysis: $e');
    } finally {
      backgroundBusy = false;
    }
  }

  void fail(String message) {
    timer?.cancel();
    unawaited(player?.pause());
    unawaited(socket?.sink.close());
    if (backgroundStarted && jobId != null && !stopping && mounted) {
      unawaited(stop());
    }
    if (mounted) {
      setState(() {
        error = message;
        playing = false;
        waiting = false;
      });
    }
  }

  void next() {
    if (backgroundStarted) return;
    if (!mounted || !playing || waiting || stopping || socket == null) return;
    final target = realTime
        ? (videoPosition.inMicroseconds * fps / 1000000).floor().clamp(0, total - 1)
        : 0;
    if (realTime && target <= lastRequestedIndex) return;
    setState(() {
      waiting = true;
      status = realTime ? 'Playing in real time' : 'Catching up…';
    });
    frameClock
      ..reset()
      ..start();
    if (realTime) lastRequestedIndex = target;
    socket!.sink.add(jsonEncode({'type': 'next', if (realTime) 'index': target}));
  }

  Future<void> startRealtimePlayer() async {
    final info = video;
    if (info == null) return;
    final p = Player();
    player = p;
    videoController = VideoController(p);
    videoPositionSubscription = p.stream.position.listen((position) {
      if (!mounted) return;
      setState(() => videoPosition = position);
      next();
    });
    videoCompletedSubscription = p.stream.completed.listen((done) {
      if (done && mounted && !stopping) unawaited(stop(naturalEnd: true));
    });
    videoErrorSubscription = p.stream.error.listen((_) {
      if (mounted && !stopping) {
        fail('Could not play this video. Try a supported MP4 or use frame-by-frame mode.');
      }
    });
    try {
      final api = ref.read(apiClientProvider);
      await p.open(Media(api.sourceVideoUrl(info.id), httpHeaders: api.authHeaders), play: false);
      await p.setVolume(0);
      if (!mounted || stopping) return;
      setState(() {
        playing = true;
        status = 'Playing · background analysis';
      });
      await p.play();
      next();
    } catch (_) {
      fail(
        'Could not play this video. Try an MP4 supported by your browser, or use frame-by-frame mode.',
      );
    }
  }

  void onMessage(dynamic raw) {
    if (!mounted || raw is! String) return;
    final msg = jsonDecode(raw) as Map<String, dynamic>;
    switch (msg['type']) {
      case 'started':
        if ((msg['frames'] as int? ?? 0) <= 0) {
          fail('This video has no readable frames.');
          return;
        }
        setState(() {
          fps = (msg['fps'] as num).toDouble();
          total = msg['frames'] as int;
          frameWidth = msg['width'] as int;
          frameHeight = msg['height'] as int;
          synthetic = (msg['stages'] as Map?)?['synthetic'] == true;
          final stages = msg['stages'] as Map?;
          modelsMissing = stages?['tracking'] == false || stages?['pose'] == false;
          started = true;
          playing = !realTime;
          status = realTime ? 'Opening video…' : 'Playing';
        });
        if (realTime) {
          unawaited(startRealtimePlayer());
        } else {
          next();
        }
      case 'video_frame':
        frameClock.stop();
        if (!playing && !stopping) {
          pendingFrame = raw;
          return;
        }
        setState(() {
          if (!realTime) image = base64Decode(msg['jpeg'] as String);
          index = (msg['index'] as int) + 1;
          lastAnalyzedIndex = msg['index'] as int;
          waiting = false;
          status = stopping
              ? 'Saving…'
              : playing
              ? (realTime ? 'Playing in real time' : 'Playing')
              : 'Paused';
          for (final event in (msg['events'] as List).cast<Map<String, dynamic>>()) {
            if (event['type'] == 'frame') {
              frameData = event;
              rally = (event['rally_state'] ?? 'Waiting').toString().replaceAll('_', ' ');
            }
            if (event['type'] == 'hit') {
              final hit = event['hit'] as Map;
              latestHit = hit['stroke'] == null ? 'Unclassified hit' : 'Stroke: ${hit['stroke']}';
              if (realTime && hit['time_s'] is num) {
                latestHit += ' at ${(hit['time_s'] as num).toStringAsFixed(1)} s';
              }
            }
            if (event['type'] == 'score' && event['score'] is Map) {
              final s = event['score'] as Map;
              score = 'Score: ${s['near'] ?? 0} – ${s['far'] ?? 0}';
            }
            if (event['type'] == 'line_call' && event['line_call'] is Map) {
              final call = event['line_call'] as Map;
              lineCall =
                  'Line call: ${call['call'] ?? 'unknown'}'
                  '${call['uncertain'] == true ? ' (review)' : ''}';
              if (realTime && call['time_s'] is num) {
                lineCall += ' at ${(call['time_s'] as num).toStringAsFixed(1)} s';
              }
            }
            if (event['type'] == 'coaching' && event['coaching'] is Map) {
              final notes = (event['coaching'] as Map)['session_notes'];
              if (notes is List) {
                coaching = notes
                    .whereType<Map>()
                    .map((n) => n['text'])
                    .whereType<String>()
                    .take(3)
                    .join('\n');
              }
            }
          }
        });
        if (playing && !stopping) {
          if (realTime) {
            next();
          } else {
            final remaining = (1000000 / fps).round() - frameClock.elapsedMicroseconds;
            timer = Timer(Duration(microseconds: remaining > 0 ? remaining : 0), next);
          }
        }
      case 'saved':
        setState(() {
          jobId = msg['job_id'] as String?;
          playing = false;
          waiting = false;
          stopping = true;
          status = 'Session saved';
        });
        ref.invalidate(jobsListProvider);
      case 'error':
        fail((msg['detail'] ?? 'Video analysis failed').toString());
    }
  }

  Future<void> stop({bool naturalEnd = false}) async {
    timer?.cancel();
    setState(() {
      playing = false;
      stopping = true;
      status = backgroundStarted ? 'Confirming stop…' : 'Saving…';
    });
    if (backgroundStarted && jobId != null) {
      final p = player;
      await p?.pause();
      final position = naturalEnd
          ? (video?.durationS ?? 0.0)
          : (p?.state.position.inMilliseconds ?? videoPosition.inMilliseconds) / 1000;
      try {
        await backgroundApi!.updateBackgroundWatch(jobId!, position, stop: true);
        if (mounted) {
          setState(() {
            stopAcknowledged = true;
            status = 'Finishing analysis…';
          });
          ref.invalidate(jobsListProvider);
          unawaited(pollBackground());
        }
      } catch (e) {
        if (mounted) {
          setState(() {
            stopping = false;
            error = 'Could not confirm stop: $e';
          });
        }
      }
      return;
    }
    unawaited(player?.pause());
    socket?.sink.add(jsonEncode({'type': 'stop'}));
  }

  @override
  void dispose() {
    timer?.cancel();
    backgroundTimer?.cancel();
    if (backgroundStarted && !stopping && jobId != null && backgroundApi != null) {
      final position =
          (player?.state.position.inMilliseconds ?? videoPosition.inMilliseconds) / 1000;
      unawaited(
        backgroundApi!
            .updateBackgroundWatch(jobId!, position, stop: true)
            .catchError((Object _) => <String, dynamic>{}),
      );
    }
    unawaited(videoPositionSubscription?.cancel());
    unawaited(videoCompletedSubscription?.cancel());
    unawaited(videoErrorSubscription?.cancel());
    unawaited(player?.dispose());
    uploadCancel?.cancel();
    if (started && !stopping && error == null) {
      socket?.sink.add(jsonEncode({'type': 'stop'}));
    }
    unawaited(subscription?.cancel());
    unawaited(socket?.sink.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final info = video;
    final health = ref.watch(healthProvider).valueOrNull;
    return PageScaffold(
      title: 'Watch & Analyze',
      actions: [
        TextButton(onPressed: () => context.go(Routes.mode), child: const Text('Change mode')),
      ],
      children: [
        if (health?.watchVideo != true)
          const Text('This backend does not support Watch & Analyze.')
        else if (info == null)
          FilledButton.icon(
            onPressed: uploading ? null : pick,
            icon: const Icon(Icons.upload_file),
            label: Text(uploading ? 'Uploading…' : 'Choose video'),
          )
        else if (socket == null && !backgroundStarted) ...[
          Text(info.filename),
          const SizedBox(height: 12),
          const Text('Playback and analysis'),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: true, label: Text('Real time')),
              ButtonSegment(value: false, label: Text('Analyze every frame')),
            ],
            selected: {realTime},
            onSelectionChanged: scanning ? null : (v) => setState(() => realTime = v.first),
          ),
          Text(
            realTime
                ? 'Video plays at normal speed while normalized frames are analyzed in the background.'
                : 'Playback waits for analysis of every sampled frame and may run slower.',
          ),
          if (realTime && health?.watchBackground != true)
            const Text(
              'Update the backend to use background analysis, or choose Analyze every frame.',
            ),
          const Text('Match format'),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('Choose manually')),
              ButtonSegment(value: true, label: Text('Suggest automatically')),
            ],
            selected: {autoMode},
            onSelectionChanged: scanning
                ? null
                : (v) => setState(() {
                    autoMode = v.first;
                    matchType = null;
                    suggestion = null;
                    suggestionDetail = null;
                  }),
          ),
          const Text('Optional calibration: tap the four singles court corners, even for doubles, in near left, near right, far right, far left order.'),
          const Text('Without court calibration, player detection is disabled.'),
          const Text('For best accuracy, use a tripod and keep the whole court in a fixed view; do not pan or zoom.'),
          SizedBox(
            height: 320,
            child: CornerCanvas(
              image: NetworkImage(ref.read(apiClientProvider).frameUrl(info.id, 0)),
              width: info.width,
              height: info.height,
              corners: corners,
              onTap: (c) {
                if (!scanning && corners.length < 4) {
                  setState(() {
                    corners.add(c);
                    if (autoMode) {
                      matchType = null;
                      suggestion = null;
                      suggestionDetail = null;
                    }
                  });
                }
              },
              onMove: (i, c) {
                if (!scanning) {
                  setState(() {
                    corners[i] = c;
                    if (autoMode) {
                      matchType = null;
                      suggestion = null;
                      suggestionDetail = null;
                    }
                  });
                }
              },
            ),
          ),
          TextButton(
            onPressed: corners.isEmpty || scanning
                ? null
                : () => setState(() {
                    corners.clear();
                    if (autoMode) {
                      matchType = null;
                      suggestion = null;
                      suggestionDetail = null;
                    }
                  }),
            child: const Text('Clear corners'),
          ),
          if (autoMode) ...[
            const Text(
              'Automatic detection requires four court corners and may be affected by spectators or hidden players.',
            ),
            OutlinedButton(
              onPressed: isConvex(corners) && !scanning && health?.watchMatchType == true
                  ? suggest
                  : null,
              child: Text(scanning ? 'Checking video…' : 'Suggest match format'),
            ),
            if (health?.watchMatchType != true)
              const Text('Automatic detection is unavailable on this server; choose manually.'),
            if (suggestionDetail != null)
              Text(
                suggestion == null
                    ? suggestionDetail!
                    : 'Suggested: $suggestion. $suggestionDetail',
              ),
          ],
          const Text('Confirm the match format:'),
          Wrap(
            spacing: 8,
            children: [
              for (final format in ['singles', 'doubles'])
                ChoiceChip(
                  label: Text(format == 'singles' ? 'Singles' : 'Doubles'),
                  selected: matchType == format,
                  onSelected: scanning || (autoMode && suggestionDetail == null)
                      ? null
                      : (_) => setState(() => matchType = format),
                ),
            ],
          ),
          FilledButton(
            onPressed:
                !scanning &&
                    matchType != null &&
                    (!realTime || health?.watchBackground == true) &&
                    (corners.isEmpty || isConvex(corners))
                ? start
                : null,
            child: const Text('Start analysis'),
          ),
        ] else ...[
          if (realTime && videoController != null)
            AspectRatio(
              aspectRatio: frameWidth / frameHeight,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Video(controller: videoController!, controls: NoVideoControls, fit: BoxFit.fill),
                  if (lastAnalyzedIndex >= 0 &&
                      (videoPosition.inMilliseconds - lastAnalyzedIndex * 1000 / fps).abs() <= 250)
                    IgnorePointer(
                      child: CustomPaint(
                        painter: _WatchOverlay(frameData, frameWidth, frameHeight),
                      ),
                    ),
                ],
              ),
            )
          else if (!realTime && image != null)
            AspectRatio(
              aspectRatio: frameWidth / frameHeight,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image.memory(image!, gaplessPlayback: true, fit: BoxFit.fill),
                  CustomPaint(painter: _WatchOverlay(frameData, frameWidth, frameHeight)),
                ],
              ),
            ),
          Text(
            '$status · ${realTime ? (videoPosition.inMilliseconds / 1000).toStringAsFixed(1) : (index / fps).toStringAsFixed(1)} s${total > 0 ? ' / ${(total / fps).toStringAsFixed(1)} s' : ''}',
          ),
          Text('Rally: $rally'),
          if (synthetic)
            const Text('Demo server: results are synthetic and do not describe this video.'),
          if (!synthetic && modelsMissing)
            const Text('Tracking or pose models are unavailable on this server.'),
          if (latestHit.isNotEmpty) Text(latestHit),
          if (score.isNotEmpty) Text(score),
          if (lineCall.isNotEmpty) Text(lineCall),
          if (coaching.isNotEmpty) Text(coaching),
          const Text('Feedback may be delayed while the rally is confirmed. Playback is silent.'),
          if (backgroundStarted)
            Text(
              'Analysis: ${analysisSeconds.toStringAsFixed(1)} s · '
              'Preview: ${(videoPosition.inMilliseconds / 1000).toStringAsFixed(1)} s. '
              'Overlays are hidden when analysis is behind.',
            ),
          if (!stopping && started && error == null)
            Wrap(
              spacing: 8,
              children: [
                FilledButton(
                  onPressed: realTime && player == null
                      ? null
                      : () {
                          setState(() {
                            playing = !playing;
                            status = playing ? 'Playing' : 'Paused';
                          });
                          if (playing) {
                            if (realTime) unawaited(player?.play());
                            final pending = pendingFrame;
                            pendingFrame = null;
                            if (pending != null) {
                              onMessage(pending);
                            } else {
                              next();
                            }
                          } else if (realTime) {
                            unawaited(player?.pause());
                          }
                        },
                  child: Text(playing ? 'Pause' : 'Play'),
                ),
                OutlinedButton(onPressed: stop, child: const Text('Stop and save')),
              ],
            ),
          if (jobId != null && (!backgroundStarted || stopAcknowledged))
            FilledButton(
              onPressed: () => context.go(Routes.job(jobId!)),
              child: Text(backgroundStarted ? 'View analysis progress' : 'View saved session'),
            ),
          if (error != null)
            OutlinedButton(
              onPressed: () {
                unawaited(subscription?.cancel());
                unawaited(socket?.sink.close());
                unawaited(videoPositionSubscription?.cancel());
                unawaited(videoCompletedSubscription?.cancel());
                unawaited(videoErrorSubscription?.cancel());
                unawaited(player?.dispose());
                setState(() {
                  socket = null;
                  subscription = null;
                  player = null;
                  videoController = null;
                  videoPosition = Duration.zero;
                  lastRequestedIndex = -1;
                  lastAnalyzedIndex = -1;
                  started = false;
                  stopAcknowledged = false;
                  stopping = false;
                  waiting = false;
                  playing = false;
                  error = null;
                  pendingFrame = null;
                  image = null;
                });
              },
              child: const Text('Try again'),
            ),
        ],
        if (error != null)
          Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
      ],
    );
  }
}

class _WatchOverlay extends CustomPainter {
  _WatchOverlay(this.frame, this.width, this.height);
  final Map<String, dynamic>? frame;
  final int width, height;
  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / width, sy = size.height / height;
    final players = frame?['display_players'] ?? frame?['players'];
    if (players is Map) {
      final paint = Paint()
        ..color = Colors.cyanAccent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2;
      for (final player in players.values) {
        if (player is! Map || player['bbox'] is! List) continue;
        final b = player['bbox'] as List;
        if (b.length < 4 || b.any((v) => v is! num)) continue;
        paint.color = (player['held'] == true)
            ? Colors.cyanAccent.withValues(alpha: 0.4)
            : Colors.cyanAccent;
        canvas.drawRect(
          Rect.fromLTWH(
            (b[0] as num) * sx,
            (b[1] as num) * sy,
            (b[2] as num) * sx,
            (b[3] as num) * sy,
          ),
          paint,
        );
      }
    }
    final shuttle = frame?['shuttle'];
    if (shuttle is Map && shuttle['visible'] == 1 && shuttle['x'] is num && shuttle['y'] is num) {
      canvas.drawRect(
        Rect.fromCenter(
          center: Offset((shuttle['x'] as num) * sx, (shuttle['y'] as num) * sy),
          width: 10,
          height: 10,
        ),
        Paint()..color = Colors.yellowAccent,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _WatchOverlay old) => old.frame != frame;
}
