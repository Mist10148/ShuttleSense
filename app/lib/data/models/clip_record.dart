import 'dart:math';
import 'json.dart';
import 'courtside.dart';
export 'courtside.dart';

typedef CourtPoint = ({double x, double y});

/// Display name of a side (near, far) or a doubles slot (near_1 -> Near 1, far_2 -> Far 2).
String playerLabel(String who) {
  final side = who.startsWith('near') ? 'Near' : 'Far';
  return who.endsWith('_1') || who.endsWith('_2') ? '$side ${who.substring(who.length - 1)}' : side;
}

/// The side (near or far) of a side or a doubles slot (near_2 -> near).
String sideOf(String who) => who.startsWith('near') ? 'near' : 'far';

/// Dart mirror of the parts of the clip record the app displays.
/// Source of truth: backend/shuttlesense/schema.py and docs/DATA_FORMAT.md.
class ClipRecord {
  const ClipRecord({
    required this.schemaVersion,
    required this.clipId,
    required this.fps,
    required this.width,
    required this.height,
    required this.numFrames,
    required this.frames,
    required this.hits,
    this.rallies = const [],
    this.courtCorners,
    this.score,
    this.summary,
    this.mode = 'upload',
    this.lineCalls = const [],
    this.rallyEvents = const [],
    this.coaching,
    this.chat = const [],
    this.court,
    this.strokeModel,
    this.decisionLog = const [],
    this.practiceGoals = const [],
    this.intervalState,
  });

  final String schemaVersion;
  final String clipId;
  final double fps;
  final int width;
  final int height;
  final int numFrames;
  final List<CourtPoint>? courtCorners;
  final List<FrameInfo> frames;
  final List<Hit> hits;
  final List<Rally> rallies;
  final Score? score;
  final Summary? summary;

  /// upload or live (schema 1.1).
  final String mode;
  final List<LineCall> lineCalls;
  final List<RallyEvent> rallyEvents;
  final Coaching? coaching;
  final List<ChatMessage> chat;

  /// "doubles" when the match was set up as doubles (a live session), even before the data
  /// shows it; null for records, which tell from their data.
  final String? court;

  /// The stroke model that named the hits (cnn, lstm, rf; clip record 1.4), if any ran.
  final String? strokeModel;
  final List<DecisionEntry> decisionLog;
  final List<PracticeGoal> practiceGoals;
  final IntervalState? intervalState;

  bool get isLive => mode == 'live';

  /// The line call for [rallyIndex], if one was made.
  LineCall? lineCallFor(int rallyIndex) {
    for (final c in lineCalls) {
      if (c.rallyIndex == rallyIndex) return c;
    }
    return null;
  }

  /// The latest line call at or before [frameIndex].
  LineCall? lineCallAt(int frameIndex) {
    LineCall? last;
    for (final c in lineCalls) {
      if (c.frame > frameIndex) break;
      last = c;
    }
    return last;
  }

  /// The frame shown at [position]. Players report positions in whole microseconds, a hair
  /// before a frame's start (1/30 s is 33333.3 µs), so a tiny tolerance keeps that frame
  /// from reading as the previous one.
  int frameAt(Duration position) =>
      frameIndexAt(position, fps).clamp(0, numFrames == 0 ? 0 : numFrames - 1);

  FrameInfo? frame(int index) => index >= 0 && index < frames.length ? frames[index] : null;

  /// The latest hit at or before [frameIndex].
  Hit? hitAt(int frameIndex) {
    Hit? last;
    for (final h in hits) {
      if (h.frame > frameIndex) break;
      last = h;
    }
    return last;
  }

  /// A doubles record: partners tracked, a partner credited with a hit, or doubles calls.
  bool get isDoubles =>
      court == 'doubles' ||
      lineCalls.any((c) => c.court == 'doubles') ||
      hits.any((h) => h.hitter != null) ||
      frames.any((f) => f.near2Pos != null || f.far2Pos != null);

  /// The rally containing [frameIndex], if any.
  Rally? rallyAt(int frameIndex) {
    for (final r in rallies) {
      if (r.startFrame <= frameIndex && frameIndex <= r.endFrame) return r;
    }
    return null;
  }

  /// The rally a let at [frameIndex] replays: the one in play there, else the last one
  /// that ended before it. Null before the first rally: there is nothing to replay yet.
  Rally? rallyToReplay(int frameIndex) {
    final playing = rallyAt(frameIndex);
    if (playing != null) return playing;
    Rally? last;
    for (final r in rallies) {
      if (r.endFrame <= frameIndex && (last == null || r.endFrame >= last.endFrame)) last = r;
    }
    return last;
  }

  /// Whether this record is clip record 1.[minor] or newer.
  bool atLeast(int minor) {
    final parts = schemaVersion.split('.');
    final major = int.tryParse(parts.first) ?? 0;
    final have = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
    return major > 1 || (major == 1 && have >= minor);
  }

  /// Score shown at [frameIndex]: after the last rally that ended at or before it, plus the
  /// points awarded since (an award counts from its frame on). Before the first scored rally
  /// ends this is the starting score. Null without a referee.
  ScorePair? scoreAt(int frameIndex) => _scoreAndEnds(frameIndex)?.score;

  /// Whether the players had changed ends at [frameIndex] (clip record 1.7): near and far
  /// in the score shown there are the ends as they stood then.
  bool endsSwappedAt(int frameIndex) => _scoreAndEnds(frameIndex)?.swapped ?? false;

  ({ScorePair score, bool swapped})? _scoreAndEnds(int frameIndex) {
    final total = score;
    if (total == null) return null;
    final awards = total.corrections.where((c) => c.isAward && c.winnerAfter != null).toList();
    ScorePair shift(ScorePair s, String? winner, int by) => ScorePair(
      near: max(0, s.near + (winner == 'near' ? by : 0)),
      far: max(0, s.far + (winner == 'far' ? by : 0)),
    );
    final first = rallies.where((r) => r.scoreAfter != null).firstOrNull;
    // Awards placed before rally k count in rally k's score_after; the start score has none.
    // No scored rally (none detected, or the start score is already a finished game): the
    // final score is the start score plus every award.
    var current = ScorePair(near: total.near, far: total.far);
    var counted = (int rallyIndex) => true; // awards already in `current`
    if (first != null) {
      current = shift(first.scoreAfter!, first.winner, -1);
      counted = (i) => i <= first.index;
    }
    for (final a in awards.where((a) => counted(a.rallyIndex))) {
      current = shift(current, a.winnerAfter, -1);
    }
    int? last;
    // `shown` is how the ends stood when `current` was true, `now` how they stand at the
    // frame: the pair is turned when they differ, so the score follows the players.
    var shown = first?.endsSwapped ?? false;
    var now = shown;
    for (final r in rallies) {
      if (r.endFrame <= frameIndex && r.scoreAfter != null) {
        current = r.scoreAfter!;
        last = r.index;
        shown = r.endsSwapped;
        now = r.endsSwapped != r.changeEnds;
      }
    }
    for (final a in awards) {
      final after = last == null ? true : a.rallyIndex > last;
      if (after && (a.frame ?? 0) <= frameIndex) current = shift(current, a.winnerAfter, 1);
    }
    for (final c in total.corrections.where((c) => c.isEnds)) {
      final since = last == null
          ? (first == null || c.rallyIndex <= first.index)
          : c.rallyIndex > last;
      if (since && (c.frame ?? 0) <= frameIndex) now = !now;
    }
    return (
      score: now == shown ? current : ScorePair(near: current.far, far: current.near),
      swapped: now,
    );
  }

  /// Strokes so far in the rally containing [frameIndex] (whole clip without rallies).
  int strokesSoFar(int frameIndex) {
    var start = 0;
    for (final r in rallies) {
      if (r.startFrame <= frameIndex) start = r.startFrame;
    }
    return hits.where((h) => h.frame >= start && h.frame <= frameIndex).length;
  }

  ClipRecord copyWith({
    List<Rally>? rallies,
    Score? score,
    List<LineCall>? lineCalls,
    List<ChatMessage>? chat,
  }) => ClipRecord(
    schemaVersion: schemaVersion,
    clipId: clipId,
    fps: fps,
    width: width,
    height: height,
    numFrames: numFrames,
    frames: frames,
    hits: hits,
    rallies: rallies ?? this.rallies,
    courtCorners: courtCorners,
    score: score ?? this.score,
    summary: summary,
    mode: mode,
    lineCalls: lineCalls ?? this.lineCalls,
    rallyEvents: rallyEvents,
    coaching: coaching,
    chat: chat ?? this.chat,
    court: court,
    strokeModel: strokeModel,
    decisionLog: decisionLog,
    practiceGoals: practiceGoals,
    intervalState: intervalState,
  );

  factory ClipRecord.fromJson(Json j) {
    final court = j['court'] as Json?;
    return ClipRecord(
      schemaVersion: j['schema_version'] as String,
      clipId: j['clip_id'] as String,
      fps: asDouble(j['fps'])!,
      width: asInt(j['width'])!,
      height: asInt(j['height'])!,
      numFrames: asInt(j['num_frames'])!,
      courtCorners: court == null
          ? null
          : (court['corners_px'] as List<dynamic>).map((p) => asPoint(p)!).toList(),
      frames: asList(j['frames']).map(FrameInfo.fromJson).toList(),
      hits: asList(j['hits']).map(Hit.fromJson).toList(),
      rallies: asList(j['rallies']).map(Rally.fromJson).toList(),
      score: j['score'] == null ? null : Score.fromJson(j['score'] as Json),
      summary: j['summary'] == null ? null : Summary.fromJson(j['summary'] as Json),
      mode: j['mode'] as String? ?? 'upload',
      lineCalls: asList(j['line_calls']).map(LineCall.fromJson).toList(),
      rallyEvents: asList(j['rally_events']).map(RallyEvent.fromJson).toList(),
      coaching: j['coaching'] == null ? null : Coaching.fromJson(j['coaching'] as Json),
      chat: asList((j['chat'] as Json?)?['messages']).map(ChatMessage.fromJson).toList(),
      strokeModel: j['stroke_model'] as String?,
      decisionLog: asList(j['decision_log']).map(DecisionEntry.fromJson).toList(),
      practiceGoals: asList(j['practice_goals']).map(PracticeGoal.fromJson).toList(),
      intervalState: j['interval_state'] == null
          ? null
          : IntervalState.fromJson(j['interval_state'] as Json),
    );
  }
}

class FrameInfo {
  const FrameInfo({
    required this.frame,
    this.nearPos,
    this.farPos,
    this.shuttlePos,
    this.shuttlePixel,
    this.playerVideoAnchors = const {},
    this.shuttleSpeedKmh,
    this.rallyState,
    this.near2Pos,
    this.far2Pos,
    this.playerHoldSafe = true,
  });

  final int frame;
  final bool playerHoldSafe;

  /// Court-plane positions in meters (null without calibration). In doubles nearPos and
  /// farPos are near_1 and far_1, and their partners are [near2Pos] and [far2Pos].
  final CourtPoint? nearPos;
  final CourtPoint? farPos;
  final CourtPoint? near2Pos;
  final CourtPoint? far2Pos;
  final CourtPoint? shuttlePos;
  final ({double x, double y})? shuttlePixel;
  final Map<String, ({double x, double y})> playerVideoAnchors;

  static Map<String, ({double x, double y})> readPlayerVideoAnchors(Object? value) {
    if (value is! Map) return const {};
    final result = <String, ({double x, double y})>{};
    for (final slot in ['near', 'far', 'near_2', 'far_2']) {
      final player = value[slot];
      final box = player is Map ? player['bbox'] : null;
      if (box is! List || box.length != 4) continue;
      final x = asDouble(box[0]), y = asDouble(box[1]), width = asDouble(box[2]);
      if (x == null || y == null || width == null || width <= 0) continue;
      result[slot] = (x: x + width / 2, y: y);
    }
    return result;
  }

  static ({double x, double y})? visibleShuttlePixel(Object? value) {
    if (value is! Map || value['visible'] != 1) return null;
    final x = asDouble(value['x']), y = asDouble(value['y']);
    if (x == null || y == null || !x.isFinite || !y.isFinite) return null;
    return (x: x, y: y);
  }

  final double? shuttleSpeedKmh;

  /// in_play or between_rallies.
  final String? rallyState;

  /// Court position of a player slot (near_1, near_2, far_1, far_2) or side (near, far).
  CourtPoint? positionOf(String player) => switch (player) {
    'near' || 'near_1' => nearPos,
    'far' || 'far_1' => farPos,
    'near_2' => near2Pos,
    'far_2' => far2Pos,
    _ => null,
  };

  factory FrameInfo.fromJson(Json j) {
    final pos = j['court_positions'] as Json?;
    return FrameInfo(
      frame: asInt(j['frame'])!,
      playerHoldSafe: j['player_hold_safe'] as bool? ?? true,
      nearPos: asPoint(pos?['near']),
      farPos: asPoint(pos?['far']),
      near2Pos: asPoint(pos?['near_2']),
      far2Pos: asPoint(pos?['far_2']),
      shuttlePos: asPoint(pos?['shuttle']),
      shuttlePixel: visibleShuttlePixel(j['shuttle']),
      playerVideoAnchors: readPlayerVideoAnchors(j['players']),
      shuttleSpeedKmh: asDouble(j['shuttle_speed_kmh']),
      rallyState: j['rally_state'] as String?,
    );
  }
}

class Hit {
  const Hit({
    required this.id,
    required this.frame,
    required this.timeS,
    required this.player,
    this.stroke,
    this.confidence,
    this.speedKmh,
    this.feedback = const [],
    this.classProbs = const {},
    this.rallyIndex,
    this.hitter,
    this.hitterConfidence,
  });

  final int id;
  final int frame;
  final double timeS;

  /// near or far.
  final String player;
  final String? stroke;
  final double? confidence;
  final double? speedKmh;

  /// Form feedback rules evaluated for this hit (docs/FEEDBACK_RULES.md).
  final List<FeedbackItem> feedback;
  final Map<String, double> classProbs;
  final int? rallyIndex;

  /// Doubles: which partner hit (near_1, near_2, far_1, far_2); null in singles or when the
  /// two partners were too close to tell.
  final String? hitter;
  final double? hitterConfidence;

  /// The slot who hit in doubles, else the side.
  String get who => hitter ?? player;

  /// First failed-rule tip from the form feedback, if any.
  String? get tip {
    for (final fb in feedback) {
      if (!fb.passed && fb.tip != null) return fb.tip;
    }
    return null;
  }

  /// Low-confidence predictions are shown with a "?".
  bool get uncertain => confidence != null && confidence! < 0.5;

  Duration get position => Duration(microseconds: (timeS * Duration.microsecondsPerSecond).round());

  factory Hit.fromJson(Json j) {
    return Hit(
      id: asInt(j['id'])!,
      frame: asInt(j['frame'])!,
      timeS: asDouble(j['time_s'])!,
      player: j['player'] as String,
      stroke: j['stroke'] as String?,
      confidence: asDouble(j['confidence']),
      speedKmh: asDouble(j['speed_kmh']),
      feedback: asList(j['feedback']).map(FeedbackItem.fromJson).toList(),
      classProbs: (j['class_probs'] as Map? ?? const {}).map(
        (k, v) => MapEntry(k as String, (v as num).toDouble()),
      ),
      rallyIndex: asInt(j['rally_index']),
      hitter: j['hitter'] as String?,
      hitterConfidence: asDouble(j['hitter_confidence']),
    );
  }
}

class FeedbackItem {
  const FeedbackItem({required this.rule, required this.passed, this.tip, this.value});

  final String rule;
  final bool passed;
  final String? tip;

  /// The measured quantity the rule checked (degrees, ratio, ...), when known.
  final double? value;

  /// "elbow_extension" -> "Elbow extension".
  String get label {
    final words = rule.replaceAll('_', ' ');
    return words.isEmpty ? words : words[0].toUpperCase() + words.substring(1);
  }

  factory FeedbackItem.fromJson(Json j) => FeedbackItem(
    rule: j['rule'] as String,
    passed: j['passed'] as bool,
    tip: j['tip'] as String?,
    value: asDouble(j['value']),
  );
}

class ScorePair {
  const ScorePair({required this.near, required this.far});

  final int near;
  final int far;

  factory ScorePair.fromJson(Json j) => ScorePair(near: asInt(j['near'])!, far: asInt(j['far'])!);

  @override
  bool operator ==(Object other) => other is ScorePair && other.near == near && other.far == far;

  @override
  int get hashCode => Object.hash(near, far);

  @override
  String toString() => '$near-$far';
}

class ScoreCorrection {
  const ScoreCorrection({
    required this.rallyIndex,
    this.winnerBefore,
    this.winnerAfter,
    this.kind = 'winner',
    this.frame,
    this.reason,
  });

  final int rallyIndex;
  final String? winnerBefore;

  /// null: the rally was made undecided again.
  final String? winnerAfter;

  /// `winner` (a rally's winner set or cleared), `award` (a point the system missed) or
  /// `concede` (the other side retired, v1.5).
  final String kind;
  final int? frame;

  /// Why the referee decided it (v1.5): `let`, `fault`, `service_fault` or `misconduct`.
  final String? reason;

  bool get isAward => kind == 'award';
  bool get isConcede => kind == 'concede';

  /// The players changed ends there, marked by hand (v1.7).
  bool get isEnds => kind == 'ends';

  /// A rally cleared to be replayed.
  bool get isLet => kind == 'winner' && winnerAfter == null && reason == 'let';

  factory ScoreCorrection.fromJson(Json j) => ScoreCorrection(
    rallyIndex: asInt(j['rally_index'])!,
    winnerBefore: j['winner_before'] as String?,
    winnerAfter: j['winner_after'] as String?,
    kind: j['kind'] as String? ?? 'winner',
    frame: asInt(j['frame']),
    reason: j['reason'] as String?,
  );
}

/// Doubles (v1.3): who serves and receives first in a game after the first (D23).
class GameService {
  const GameService({required this.game, required this.serverId, required this.receiverId});

  final int game;
  final String serverId;
  final String receiverId;

  factory GameService.fromJson(Json j) => GameService(
    game: asInt(j['game'])!,
    serverId: j['server_id'] as String,
    receiverId: j['receiver_id'] as String,
  );
}

/// The current game's score (the last game's once the match is over) and the match state,
/// all derived by the backend from the rally winners (D21).
class Score extends ScorePair {
  const Score({
    required super.near,
    required super.far,
    this.corrections = const [],
    this.bestOf = 1,
    this.firstServer,
    this.game = 1,
    this.games = const [],
    this.gamesWon = const ScorePair(near: 0, far: 0),
    this.server,
    this.serviceCourt,
    this.gamePoint = const [],
    this.matchPoint = const [],
    this.matchWinner,
    this.interval = false,
    this.changeEnds = false,
    this.firstServerId,
    this.firstReceiverId,
    this.serverId,
    this.receiverId,
    this.gameService = const [],
    this.startGames,
    this.intervalSeconds,
    this.autoChangeEnds = false,
    this.endsSwapped = false,
  });

  final List<ScoreCorrection> corrections;
  final int bestOf;
  final String? firstServer;
  final int game;

  /// Finished games, in order.
  final List<ScorePair> games;
  final ScorePair gamesWon;

  /// Who serves the next rally, and from which court (`right` / `left`); null if unknown.
  final String? server;
  final String? serviceCourt;
  final List<String> gamePoint;
  final List<String> matchPoint;
  final String? matchWinner;

  /// The leader reached 11 (60 s interval) or a game just ended (120 s).
  final bool interval;

  /// How long that interval is (v1.5); null from older backends.
  final int? intervalSeconds;

  /// Games each side had already won when the session started (joined mid-match, v1.5).
  final ScorePair? startGames;

  /// Doubles (v1.3): the first server and receiver the user named for games 2 and 3.
  final List<GameService> gameService;

  /// Players change ends now: after a game, and at 11 in the deciding game.
  final bool changeEnds;

  /// Clip record 1.7: the score follows the players by the rules, and whether the side
  /// that started at the near end is at the far end now. Near and far are always the
  /// ends as they are.
  final bool autoChangeEnds;
  final bool endsSwapped;

  /// Doubles: the slots who served and received first (set by the user), and who serves
  /// and receives the next rally.
  final String? firstServerId;
  final String? firstReceiverId;
  final String? serverId;
  final String? receiverId;

  bool get matchOver => matchWinner != null;

  /// The other side retired or gave a walkover.
  bool get conceded => corrections.any((c) => c.isConcede);

  /// The game number of the first game in [games] (later than 1 after a mid-match start).
  int get firstGame => 1 + (startGames?.near ?? 0) + (startGames?.far ?? 0);

  factory Score.fromJson(Json j) => Score(
    near: asInt(j['near'])!,
    far: asInt(j['far'])!,
    corrections: asList(j['corrections']).map(ScoreCorrection.fromJson).toList(),
    bestOf: asInt(j['best_of']) ?? 1,
    firstServer: j['first_server'] as String?,
    game: asInt(j['game']) ?? 1,
    games: asList(j['games']).map(ScorePair.fromJson).toList(),
    gamesWon: j['games_won'] == null
        ? const ScorePair(near: 0, far: 0)
        : ScorePair.fromJson(j['games_won'] as Json),
    server: j['server'] as String?,
    serviceCourt: j['service_court'] as String?,
    gamePoint: [for (final s in j['game_point'] as List? ?? const []) s as String],
    matchPoint: [for (final s in j['match_point'] as List? ?? const []) s as String],
    matchWinner: j['match_winner'] as String?,
    interval: j['interval'] as bool? ?? false,
    changeEnds: j['change_ends'] as bool? ?? false,
    firstServerId: j['first_server_id'] as String?,
    firstReceiverId: j['first_receiver_id'] as String?,
    serverId: j['server_id'] as String?,
    receiverId: j['receiver_id'] as String?,
    gameService: asList(j['game_service']).map(GameService.fromJson).toList(),
    startGames: j['start_games'] == null ? null : ScorePair.fromJson(j['start_games'] as Json),
    intervalSeconds: asInt(j['interval_s']),
    autoChangeEnds: j['auto_change_ends'] == true,
    endsSwapped: j['ends_swapped'] == true,
  );
}

class Landing {
  const Landing({
    required this.x,
    required this.y,
    required this.inCourt,
    required this.confidence,
  });

  final double x;
  final double y;
  final bool inCourt;
  final double confidence;

  /// Close calls are never awarded automatically; the user confirms them.
  bool get uncertain => confidence < 0.5;

  factory Landing.fromJson(Json j) => Landing(
    x: asDouble(j['x_m'])!,
    y: asDouble(j['y_m'])!,
    inCourt: j['in_court'] as bool,
    confidence: asDouble(j['confidence'])!,
  );
}

class Rally {
  const Rally({
    required this.index,
    required this.startFrame,
    required this.endFrame,
    this.strokeCount = 0,
    this.landing,
    this.winner,
    this.scoreAfter,
    this.game = 1,
    this.serverId,
    this.receiverId,
    this.review,
    this.endsSwapped = false,
    this.changeEnds = false,
  });

  final int index;
  final int startFrame;
  final int endFrame;
  final int strokeCount;
  final Landing? landing;

  /// near, far, or null when the rally is open or the call is uncertain.
  final String? winner;
  final ScorePair? scoreAfter;

  /// 1-based game of the match the rally was played in.
  final int game;

  /// Doubles: who served and received this rally.
  final String? serverId;
  final String? receiverId;

  /// Why the user should check this rally (e.g. the server stood in the wrong court).
  final String? review;

  /// Clip record 1.7: the players had changed ends when this rally was played (its
  /// winner and score are by the ends then), and they changed ends right after it.
  final bool endsSwapped;
  final bool changeEnds;

  factory Rally.fromJson(Json j) => Rally(
    index: asInt(j['index'])!,
    startFrame: asInt(j['start_frame'])!,
    endFrame: asInt(j['end_frame'])!,
    strokeCount: asInt(j['stroke_count']) ?? 0,
    landing: j['landing'] == null ? null : Landing.fromJson(j['landing'] as Json),
    winner: j['winner'] as String?,
    scoreAfter: j['score_after'] == null ? null : ScorePair.fromJson(j['score_after'] as Json),
    game: asInt(j['game']) ?? 1,
    serverId: j['server_id'] as String?,
    receiverId: j['receiver_id'] as String?,
    review: j['review'] as String?,
    endsSwapped: j['ends_swapped'] == true,
    changeEnds: j['change_ends'] == true,
  );
}

/// PATCH /jobs/{id}/line-calls/{n} response.
class LineCallUpdate {
  const LineCallUpdate({required this.lineCalls, required this.score, required this.rallies});

  final List<LineCall> lineCalls;
  final Score score;
  final List<Rally> rallies;

  factory LineCallUpdate.fromJson(Json j) => LineCallUpdate(
    lineCalls: asList(j['line_calls']).map(LineCall.fromJson).toList(),
    score: Score.fromJson(j['score'] as Json),
    rallies: asList(j['rallies']).map(Rally.fromJson).toList(),
  );
}

/// PATCH /jobs/{id}/score response.
class ScoreUpdate {
  const ScoreUpdate({required this.score, required this.rallies, this.lineCalls});

  final Score score;
  final List<Rally> rallies;

  /// Set by an undo, which can take back a line-call override (D32).
  final List<LineCall>? lineCalls;

  factory ScoreUpdate.fromJson(Json j) => ScoreUpdate(
    score: Score.fromJson(j['score'] as Json),
    rallies: asList(j['rallies']).map(Rally.fromJson).toList(),
    lineCalls: j['line_calls'] == null
        ? null
        : asList(j['line_calls']).map(LineCall.fromJson).toList(),
  );
}

/// A point on the timeline the app can seek to.
class Moment {
  const Moment({required this.frame, required this.timeS, this.hitId});

  final int frame;
  final double timeS;
  final int? hitId;

  Duration get position => Duration(microseconds: (timeS * Duration.microsecondsPerSecond).round());

  /// "1:05.3" style label for chips.
  String get label {
    final s = timeS < 0 ? 0.0 : timeS;
    final minutes = s ~/ 60;
    final rest = (s - minutes * 60).toStringAsFixed(1).padLeft(4, '0');
    return '$minutes:$rest';
  }

  factory Moment.fromJson(Json j) =>
      Moment(frame: asInt(j['frame'])!, timeS: asDouble(j['time_s'])!, hitId: asInt(j['hit_id']));
}

/// Automated in/out call for one landing (schema 1.1). Never an official call.
class LineCall {
  const LineCall({
    required this.id,
    required this.rallyIndex,
    required this.frame,
    required this.timeS,
    required this.call,
    required this.landing,
    required this.marginCm,
    required this.confidence,
    required this.uncertain,
    this.court = 'singles',
    this.overrideCall,
  });

  final int id;
  final int rallyIndex;
  final int frame;
  final double timeS;

  /// in or out, as called by the backend.
  final String call;
  final CourtPoint landing;

  /// Signed distance to the nearest relevant line; positive inside the court.
  final double marginCm;
  final double confidence;
  final bool uncertain;
  final String court;

  /// in or out when the user confirmed or overrode the call.
  final String? overrideCall;

  String get effectiveCall => overrideCall ?? call;
  bool get isIn => effectiveCall == 'in';
  bool get reviewed => overrideCall != null;

  /// Still waiting for the user: uncertain and not yet confirmed or overridden.
  bool get needsReview => uncertain && !reviewed;

  Moment get moment => Moment(frame: frame, timeS: timeS);

  factory LineCall.fromJson(Json j) => LineCall(
    id: asInt(j['id'])!,
    rallyIndex: asInt(j['rally_index'])!,
    frame: asInt(j['frame'])!,
    timeS: asDouble(j['time_s'])!,
    call: j['call'] as String,
    landing: asPoint(j['landing_xy'])!,
    marginCm: asDouble(j['margin_cm'])!,
    confidence: asDouble(j['confidence'])!,
    uncertain: j['uncertain'] as bool,
    court: j['court'] as String? ?? 'singles',
    overrideCall: (j['override'] as Json?)?['call'] as String?,
  );
}

class RallyEvent {
  const RallyEvent({
    required this.frame,
    required this.timeS,
    required this.type,
    this.rallyIndex,
    this.data = const {},
  });

  final int frame;
  final double timeS;

  /// rally_start, rally_end, hit, landing or score.
  final String type;
  final int? rallyIndex;
  final Json data;

  factory RallyEvent.fromJson(Json j) => RallyEvent(
    frame: asInt(j['frame'])!,
    timeS: asDouble(j['time_s'])!,
    type: j['type'] as String,
    rallyIndex: asInt(j['rally_index']),
    data: (j['data'] as Json?) ?? const {},
  );
}

/// A pattern seen across the session ("Late split-step on 4 of 6 net shots").
class SessionNote {
  const SessionNote({
    required this.id,
    required this.rule,
    required this.text,
    required this.count,
    required this.total,
    required this.severity,
    this.player,
    this.stroke,
    this.moments = const [],
  });

  final String id;
  final String rule;

  /// near or far; in doubles the partner (near_1 ... far_2) when the hitter is known.
  final String? player;
  final String? stroke;
  final String text;
  final int count;
  final int total;
  final double severity;
  final List<Moment> moments;

  factory SessionNote.fromJson(Json j) => SessionNote(
    id: j['id'] as String,
    rule: j['rule'] as String,
    player: j['player'] as String?,
    stroke: j['stroke'] as String?,
    text: j['text'] as String,
    count: asInt(j['count'])!,
    total: asInt(j['total'])!,
    severity: asDouble(j['severity'])!,
    moments: asList(j['moments']).map(Moment.fromJson).toList(),
  );
}

class Coaching {
  const Coaching({this.notes = const [], this.topFixIds = const []});

  final List<SessionNote> notes;
  final List<String> topFixIds;

  /// The notes named in top_fixes, most important first.
  List<SessionNote> get topFixes => [for (final id in topFixIds) ...notes.where((n) => n.id == id)];

  static List<SessionNote> rankedFixes(Iterable<SessionNote> notes) =>
      notes.where((note) => note.severity > 0).toList()..sort((a, b) {
        final impact = (b.count * b.severity).compareTo(a.count * a.severity);
        if (impact != 0) return impact;
        final frequency = (b.count / b.total).compareTo(a.count / a.total);
        return frequency == 0 ? a.id.compareTo(b.id) : frequency;
      });

  factory Coaching.fromJson(Json j) => Coaching(
    notes: asList(j['session_notes']).map(SessionNote.fromJson).toList(),
    topFixIds: (j['top_fixes'] as List<dynamic>? ?? const []).cast<String>(),
  );
}

class ChatMessage {
  const ChatMessage({required this.role, required this.text, this.at, this.citations = const []});

  /// user or assistant.
  final String role;
  final String text;
  final DateTime? at;
  final List<Moment> citations;

  bool get fromUser => role == 'user';

  factory ChatMessage.fromJson(Json j) => ChatMessage(
    role: j['role'] as String,
    text: j['text'] as String,
    at: asDate(j['at']),
    citations: asList(j['citations']).map(Moment.fromJson).toList(),
  );
}

Map<String, int> _counts(Object? v) =>
    (v as Map? ?? const {}).map((k, v) => MapEntry(k as String, (v as num).toInt()));

class PlayerSummary {
  const PlayerSummary({required this.hits, required this.strokeCounts, this.peakSpeedKmh});

  final int hits;
  final Map<String, int> strokeCounts;
  final double? peakSpeedKmh;

  factory PlayerSummary.fromJson(Json j) => PlayerSummary(
    hits: asInt(j['hits']) ?? 0,
    strokeCounts: _counts(j['stroke_counts']),
    peakSpeedKmh: asDouble(j['peak_speed_kmh']),
  );
}

class Summary {
  const Summary({
    required this.totalHits,
    required this.strokeCounts,
    this.peakSpeedKmh,
    this.perPlayer = const {},
  });

  final int totalHits;
  final Map<String, int> strokeCounts;
  final double? peakSpeedKmh;

  /// Keyed by near / far, or by slot (near_1 ... far_2) in doubles.
  final Map<String, PlayerSummary> perPlayer;

  factory Summary.fromJson(Json j) => Summary(
    totalHits: asInt(j['total_hits']) ?? 0,
    strokeCounts: _counts(j['stroke_counts']),
    peakSpeedKmh: asDouble(j['peak_speed_kmh']),
    perPlayer: (j['per_player'] as Map? ?? const {}).map(
      (k, v) => MapEntry(k as String, PlayerSummary.fromJson(v as Json)),
    ),
  );
}

/// Display names for the six stroke classes.
const kStrokeLabels = <String, String>{
  'smash': 'Smash',
  'clear': 'Clear',
  'drop': 'Drop',
  'net_shot': 'Net shot',
  'lift': 'Lift',
  'serve': 'Serve',
};

/// Frame index at [position] for [fps], tolerant of whole-microsecond rounding.
int frameIndexAt(Duration position, double fps) =>
    (position.inMicroseconds * fps / Duration.microsecondsPerSecond + 1e-3).floor();

/// Middle of frame [index] for [fps]. Seeking there instead of to the frame start keeps a
/// player that truncates positions (media_kit on the web seeks in whole milliseconds) inside
/// the frame, so [frameIndexAt] maps the reported position back to [index].
Duration frameMid(int index, double fps) =>
    Duration(microseconds: ((index + 0.5) * Duration.microsecondsPerSecond / fps).round());
