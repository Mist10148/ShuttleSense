import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuttlesense_app/core/config/server_config.dart';
import 'package:shuttlesense_app/data/api_client.dart';
import 'package:shuttlesense_app/data/models/clip_record.dart';
import 'package:shuttlesense_app/data/models/health.dart';
import 'package:shuttlesense_app/data/models/job.dart';

// Mirrors the example in docs/DATA_FORMAT.md / backend/tests/test_schema.py.
final recordJson = <String, dynamic>{
  'schema_version': '1.1',
  'clip_id': 'match03_rally12',
  'fps': 30.0,
  'width': 1280,
  'height': 720,
  'num_frames': 900,
  'court': {
    'corners_px': [
      [212.0, 650.0],
      [1068.0, 650.0],
      [880.0, 210.0],
      [400.0, 210.0],
    ],
    'homography': [
      [1, 0, 0],
      [0, 1, 0],
      [0, 0, 1],
    ],
    'court_size_m': [5.18, 13.40],
  },
  'frames': [
    {
      'frame': 0,
      'shuttle': {'x': 512.0, 'y': 288.0, 'visible': 1},
      'players': {'near': null, 'far': null},
      'court_positions': {
        'near': [2.6, 1.9],
        'far': [2.4, 11.8],
        'shuttle': null,
      },
      'shuttle_speed_kmh': null,
      'rally_state': 'in_play',
    },
  ],
  'hits': [
    {
      'id': 0,
      'frame': 42,
      'time_s': 1.4,
      'player': 'near',
      'stroke': 'smash',
      'confidence': 0.81,
      'speed_kmh': 182.0,
      'feedback': [
        {'rule': 'contact_above_head', 'passed': true, 'tip': null},
        {'rule': 'elbow_extension', 'passed': false, 'tip': 'Extend your arm.'},
      ],
      'rally_index': 0,
    },
    {'id': 1, 'frame': 80, 'time_s': 2.67, 'player': 'far', 'feedback': []},
  ],
  'rallies': [],
  'score': {'near': 11, 'far': 9, 'corrections': []},
  'summary': {
    'total_hits': 2,
    'stroke_counts': {'smash': 1},
    'peak_speed_kmh': 182.0,
    'per_player': {},
  },
};

void main() {
  test('match state, awards and null-winner corrections parse', () {
    final score = Score.fromJson({
      'near': 3,
      'far': 1,
      'best_of': 3,
      'first_server': 'far',
      'game': 2,
      'games': [
        {'near': 21, 'far': 19},
      ],
      'games_won': {'near': 1, 'far': 0},
      'server': 'near',
      'service_court': 'left',
      'game_point': <dynamic>[],
      'match_point': <dynamic>[],
      'corrections': [
        {'rally_index': 2, 'winner_before': 'near', 'winner_after': null},
        {
          'rally_index': 4,
          'winner_before': null,
          'winner_after': 'far',
          'kind': 'award',
          'frame': 900,
        },
      ],
    });
    expect(score.game, 2);
    expect(score.games.single, const ScorePair(near: 21, far: 19));
    expect(score.gamesWon, const ScorePair(near: 1, far: 0));
    expect((score.server, score.serviceCourt), ('near', 'left'));
    expect(score.corrections.first.winnerAfter, isNull);
    expect(score.corrections.last.isAward, isTrue);
    expect(score.corrections.last.frame, 900);
    // A 1.0/early 1.1 record without the fields still parses with defaults.
    final old = Score.fromJson({'near': 1, 'far': 0});
    expect((old.bestOf, old.game, old.server, old.matchOver), (1, 1, null, false));
  });

  group('ClipRecord', () {
    final record = ClipRecord.fromJson(recordJson);

    test('parses the documented example', () {
      expect(record.clipId, 'match03_rally12');
      expect(record.courtCorners, hasLength(4));
      expect(record.frames.single.nearPos, (x: 2.6, y: 1.9));
      expect(record.frames.single.shuttlePos, isNull);
      expect(record.frames.single.rallyState, 'in_play');
      expect(record.hits.first.tip, 'Extend your arm.');
      expect(record.hits.last.stroke, isNull);
      expect(record.score!.near, 11);
      expect(record.summary!.strokeCounts, {'smash': 1});
    });

    test('maps playback position to frame and current hit', () {
      expect(record.frameAt(const Duration(seconds: 2)), 60);
      expect(record.frameAt(const Duration(hours: 1)), 899);
      // A player reports frame 1 at 30 fps as 33333 µs, just before 1/30 s.
      expect(record.frameAt(const Duration(microseconds: 33333)), 1);
      expect(record.frameAt(const Duration(microseconds: 33000)), 0);
      expect(record.hitAt(10), isNull);
      expect(record.hitAt(60)!.id, 0);
      expect(record.hitAt(100)!.id, 1);
      expect(record.hits.first.position, const Duration(milliseconds: 1400));
    });
  });

  test('parses golden record', () {
    final json = jsonDecode(File('test/fixtures/golden_record.json').readAsStringSync());
    final golden = ClipRecord.fromJson(json as Map<String, dynamic>);
    expect(golden.frames, hasLength(60));
    expect(golden.hits.map((h) => h.stroke), ['serve', 'clear', 'smash']);
    expect(golden.courtCorners, hasLength(4));
    expect(golden.summary!.totalHits, 3);
    expect(golden.summary!.perPlayer['near']!.hits, 2);
    // Full feedback list: the clear has one passed and one failed rule.
    expect(golden.hits[1].feedback, hasLength(2));
    expect(golden.hits[1].feedback.first.passed, isTrue);
    expect(golden.hits[1].tip, startsWith('Straighten'));
    expect(golden.hits[1].feedback.last.value, 132.0);
    expect(golden.hits[0].tip, startsWith('Keep both feet'));
    expect(golden.coaching!.topFixes, isNotEmpty);
    expect(golden.lineCalls.single.isIn, isTrue);
    expect(golden.hits[2].classProbs['smash'], 0.86);
    // Rallies and the score at a playback position.
    expect(golden.rallies.single.winner, 'near');
    expect(golden.rallies.single.landing!.inCourt, isTrue);
    expect(golden.scoreAt(10), const ScorePair(near: 0, far: 0));
    expect(golden.scoreAt(58), const ScorePair(near: 1, far: 0));
    // Started at 10-12 with no rally scored: the start score, not 0-0.
    final unscored = golden.copyWith(
      rallies: [const Rally(index: 0, startFrame: 0, endFrame: 40)],
      score: const Score(near: 10, far: 12),
    );
    expect(unscored.scoreAt(50), const ScorePair(near: 10, far: 12));
    // The first rally was not scored, the second was: back out the second rally's winner.
    final late = golden.copyWith(
      rallies: [
        const Rally(index: 0, startFrame: 0, endFrame: 20, winner: 'far'),
        const Rally(
          index: 1,
          startFrame: 25,
          endFrame: 50,
          winner: 'near',
          scoreAfter: ScorePair(near: 11, far: 12),
        ),
      ],
      score: const Score(near: 11, far: 12),
    );
    expect(late.scoreAt(22), const ScorePair(near: 10, far: 12));
    expect(late.scoreAt(55), const ScorePair(near: 11, far: 12));
    // Awarded points count from their frame on, before and after the scored rallies.
    final awarded = golden.copyWith(
      rallies: [
        const Rally(
          index: 0,
          startFrame: 40,
          endFrame: 50,
          winner: 'near',
          scoreAfter: ScorePair(near: 1, far: 1),
        ),
      ],
      score: const Score(
        near: 2,
        far: 1,
        corrections: [
          ScoreCorrection(rallyIndex: 0, winnerAfter: 'far', kind: 'award', frame: 30),
          ScoreCorrection(rallyIndex: 1, winnerAfter: 'near', kind: 'award', frame: 70),
        ],
      ),
    );
    expect(awarded.scoreAt(10), const ScorePair(near: 0, far: 0));
    expect(awarded.scoreAt(35), const ScorePair(near: 0, far: 1));
    expect(awarded.scoreAt(55), const ScorePair(near: 1, far: 1));
    expect(awarded.scoreAt(75), const ScorePair(near: 2, far: 1));
    final onlyAwards = golden.copyWith(
      rallies: const [],
      score: const Score(
        near: 1,
        far: 0,
        corrections: [
          ScoreCorrection(rallyIndex: 0, winnerAfter: 'near', kind: 'award', frame: 30),
        ],
      ),
    );
    expect(onlyAwards.scoreAt(10), const ScorePair(near: 0, far: 0));
    expect(onlyAwards.scoreAt(40), const ScorePair(near: 1, far: 0));
    expect(golden.strokesSoFar(30), 2);
    expect(golden.rallyAt(57), isNull);
    // A let replays the rally in play, or the last one that ended: never a later rally.
    final rallies = golden.rallies;
    expect(golden.rallyToReplay(rallies.first.startFrame)!.index, rallies.first.index);
    expect(golden.rallyToReplay(rallies.last.endFrame + 1)!.index, rallies.last.index);
    if (rallies.first.startFrame > 0) {
      expect(golden.rallyToReplay(rallies.first.startFrame - 1), isNull);
    }
    expect(golden.copyWith(rallies: const []).rallyToReplay(10), isNull);
    expect(golden.atLeast(6), golden.schemaVersion != '1.5');
    expect(golden.atLeast(0), isTrue);
    expect(golden.atLeast(99), isFalse);
  });

  test('ScoreUpdate parses the correction response', () {
    final update = ScoreUpdate.fromJson({
      'score': {
        'near': 0,
        'far': 1,
        'corrections': [
          {
            'rally_index': 0,
            'winner_before': 'near',
            'winner_after': 'far',
            'at': '2026-11-05T09:13:01Z',
          },
        ],
      },
      'rallies': [
        {
          'index': 0,
          'start_frame': 0,
          'end_frame': 10,
          'winner': 'far',
          'score_after': {'near': 0, 'far': 1},
        },
      ],
    });
    expect(update.score.corrections.single.winnerAfter, 'far');
    expect(update.rallies.single.scoreAfter, const ScorePair(near: 0, far: 1));
  });

  test('Job parses status, stages and outputs', () {
    final job = Job.fromJson({
      'id': 'f00dbabe1234',
      'video_id': 'a1b2c3d4e5f6',
      'status': 'running',
      'queue_position': null,
      'current_stage': 'pose',
      'progress': 0.42,
      'stages': [
        {'name': 'io', 'status': 'done', 'progress': 1.0},
        {'name': 'pose', 'status': 'running', 'progress': 0.35},
      ],
      'error': null,
      'created_at': '2026-11-05T09:13:01Z',
      'started_at': '2026-11-05T09:13:02Z',
      'finished_at': null,
      'outputs': {'record': false, 'video': false, 'summary': false, 'hits_csv': false},
      'overlays': ['trail', 'boxes'],
      'court_corners_px': [
        [1, 2],
        [3, 4],
        [5, 6],
        [7, 8],
      ],
      'referee': true,
    });
    expect(job.status, JobStatus.running);
    expect(job.status.isFinished, isFalse);
    expect(job.stages.last.progress, 0.35);
    expect(job.outputs.record, isFalse);
    expect(job.options.overlays, {'trail', 'boxes'});
    expect(job.options.calibrate, isTrue);
    expect(job.options.referee, isTrue);
    final now = DateTime.utc(2026, 11, 5, 9, 13, 12);
    expect(job.elapsed(now), const Duration(seconds: 10));
    expect(job.eta(now)!.inSeconds, 13); // 10 s for 42% -> about 13.8 s left
  });

  test('ServerConfig.normalizeUrl', () {
    expect(ServerConfig.normalizeUrl(' 192.168.1.20:8000/ '), 'http://192.168.1.20:8000');
    expect(
      ServerConfig.normalizeUrl('https://abc.trycloudflare.com//'),
      'https://abc.trycloudflare.com',
    );
    expect(ServerConfig.normalizeUrl(''), '');
  });

  test('server error details: strings, 422 lists, and non-JSON bodies', () {
    expect(errorDetail({'detail': 'upload too large'}), 'upload too large');
    expect(
      errorDetail({
        'detail': [
          {
            'loc': ['body', 'rally_index'],
            'msg': 'Field required',
            'type': 'missing',
          },
        ],
      }),
      'Field required',
    );
    expect(errorDetail('<html>413 Request Entity Too Large</html>'), isNull);
    expect(errorDetail(null), isNull);
  });

  test('unknown job status keeps polling; elapsed never negative', () {
    expect(JobStatus.parse('done'), JobStatus.done);
    expect(JobStatus.parse('cancelling'), JobStatus.running);
    final job = Job.fromJson({
      'id': 'j',
      'video_id': 'v',
      'status': 'running',
      'progress': 0.5,
      'stages': <dynamic>[],
      'created_at': '2026-11-05T09:13:01Z',
      'started_at': '2026-11-05T09:13:01Z',
    });
    expect(job.elapsed(DateTime.utc(2026, 11, 5, 9, 12)), Duration.zero);
  });

  test('a retried job keeps its start score', () {
    final job = Job.fromJson({
      'id': 'j',
      'video_id': 'v',
      'status': 'failed',
      'progress': 0.2,
      'stages': <dynamic>[],
      'created_at': '2026-11-05T09:13:01Z',
      'referee': true,
      'start_score': {'near': 11, 'far': 9},
    });
    expect(job.options.startScore, (near: 11, far: 9));
  });

  test('parses schema 1.1 fields and accepts any 1.x backend', () {
    final record = ClipRecord.fromJson({
      'schema_version': '1.1',
      'clip_id': 'c',
      'mode': 'live',
      'fps': 30,
      'width': 1280,
      'height': 720,
      'num_frames': 90,
      'frames': <dynamic>[],
      'hits': <dynamic>[],
      'line_calls': [
        {
          'id': 0,
          'rally_index': 0,
          'frame': 60,
          'time_s': 2.0,
          'call': 'out',
          'landing_xy': [5.3, 6.0],
          'margin_cm': -6.0,
          'confidence': 0.3,
          'uncertain': true,
          'court': 'singles',
          'override': {'call': 'in', 'at': '2026-10-31T10:00:00Z'},
        },
      ],
      'coaching': {
        'session_notes': [
          {
            'id': 'a',
            'rule': 'elbow_extension',
            'stroke': 'smash',
            'text': 'Bent elbow at contact on 3 of 5 smashes',
            'count': 3,
            'total': 5,
            'severity': 1.0,
            'moments': [
              {'frame': 30, 'time_s': 65.25, 'hit_id': 2},
            ],
          },
        ],
        'top_fixes': ['a', 'missing'],
      },
      'chat': {
        'messages': [
          {'role': 'user', 'text': 'Why?', 'at': '2026-10-31T10:00:00Z', 'citations': <dynamic>[]},
        ],
      },
    });
    expect(record.isLive, isTrue);
    final call = record.lineCalls.single;
    expect(call.effectiveCall, 'in');
    expect(call.needsReview, isFalse);
    expect(record.lineCallAt(59), isNull);
    expect(record.lineCallFor(0), same(call));
    expect(record.coaching!.topFixes.single.moments.single.label, '1:05.3');
    expect(record.chat.single.fromUser, isTrue);
    // A 1.0 record without the new fields still parses.
    final golden = ClipRecord.fromJson(
      jsonDecode(File('test/fixtures/golden_record.json').readAsStringSync())
          as Map<String, dynamic>,
    );
    expect(golden.mode, 'upload');
    final health = Health.fromJson({
      'version': '0.1.0',
      'schema_version': '1.0',
      'device': 'cpu',
      'auth_required': false,
      'stages': <dynamic>[],
    });
    expect(health.schemaMatches, isTrue);
  });

  test('a doubles record (1.2) parses partners, hitters and the service order', () {
    final doubles = ClipRecord.fromJson(
      jsonDecode(File('test/fixtures/golden_record_doubles.json').readAsStringSync())
          as Map<String, dynamic>,
    );
    expect(doubles.frames.every((f) => f.near2Pos != null && f.far2Pos != null), isTrue);
    expect(doubles.frames.first.positionOf('near_2'), doubles.frames.first.near2Pos);
    expect(doubles.frames.first.positionOf('far'), doubles.frames.first.farPos);
    expect(doubles.hits.map((h) => h.hitter), ['near_1', 'far_1', 'near_2']);
    expect(doubles.hits.last.who, 'near_2');
    expect(doubles.hits.last.player, 'near');
    expect(doubles.score!.firstServerId, 'near_1');
    expect(doubles.score!.firstReceiverId, 'far_1');
    expect((doubles.score!.serverId, doubles.score!.receiverId), ('near_1', 'far_2'));
    expect(doubles.rallies.single.serverId, 'near_1');
    expect(doubles.lineCalls.single.court, 'doubles');
    // Singles records have none of it.
    final singles = ClipRecord.fromJson(
      jsonDecode(File('test/fixtures/golden_record.json').readAsStringSync())
          as Map<String, dynamic>,
    );
    expect(singles.hits.every((h) => h.hitter == null && h.who == h.player), isTrue);
    expect(singles.score!.serverId, isNull);
  });

  test('the score at a playback position follows the players across a change of ends', () {
    Map<String, dynamic> rally(
      int i, {
      bool swapped = false,
      bool change = false,
      int? n,
      int? f,
    }) => {
      'index': i,
      'start_frame': 10 * i,
      'end_frame': 10 * i + 5,
      'winner': 'near',
      'score_after': {'near': n, 'far': f},
      if (swapped) 'ends_swapped': true,
      if (change) 'change_ends': true,
    };
    Map<String, dynamic> record(Map<String, dynamic> score, List<Map<String, dynamic>> rallies) => {
      'schema_version': '1.7',
      'clip_id': 'ends',
      'fps': 30,
      'width': 640,
      'height': 360,
      'num_frames': 60,
      'rallies': rallies,
      'score': score,
    };

    // By rule: 9-4, two points at the near end reach 11, the players cross, one more point.
    final byRule = ClipRecord.fromJson(
      record(
        {'near': 5, 'far': 11, 'auto_change_ends': true, 'ends_swapped': true},
        [
          rally(0, n: 10, f: 4),
          rally(1, n: 11, f: 4, change: true),
          rally(2, n: 5, f: 11, swapped: true),
        ],
      ),
    );
    expect(byRule.score!.autoChangeEnds && byRule.score!.endsSwapped, isTrue);
    expect(byRule.rallies[1].changeEnds && byRule.rallies[2].endsSwapped, isTrue);
    expect(byRule.scoreAt(4), const ScorePair(near: 9, far: 4));
    expect(byRule.scoreAt(6), const ScorePair(near: 10, far: 4));
    expect(byRule.endsSwappedAt(6), isFalse);
    expect(byRule.scoreAt(16), const ScorePair(near: 4, far: 11)); // 11-4, from the new ends
    expect(byRule.endsSwappedAt(16), isTrue);
    expect(byRule.scoreAt(26), const ScorePair(near: 5, far: 11));

    // By hand, at frame 17, after two rallies.
    final byHand = ClipRecord.fromJson(
      record(
        {
          'near': 1,
          'far': 2,
          'ends_swapped': true,
          'corrections': [
            {
              'rally_index': 2,
              'winner_before': null,
              'winner_after': null,
              'at': '2026-11-15T10:00:00Z',
              'kind': 'ends',
              'frame': 17,
            },
          ],
        },
        [rally(0, n: 1, f: 0), rally(1, n: 2, f: 0), rally(2, n: 1, f: 2, swapped: true)],
      ),
    );
    expect(byHand.score!.corrections.single.isEnds, isTrue);
    expect(byHand.score!.corrections.single.isAward, isFalse);
    expect(byHand.scoreAt(16), const ScorePair(near: 2, far: 0));
    expect(byHand.scoreAt(17), const ScorePair(near: 0, far: 2));
    expect(byHand.endsSwappedAt(16), isFalse);
    expect(byHand.endsSwappedAt(17), isTrue);
    expect(byHand.scoreAt(26), const ScorePair(near: 1, far: 2));

    // An older record has no change of ends.
    final golden = ClipRecord.fromJson(
      jsonDecode(File('test/fixtures/golden_record.json').readAsStringSync())
          as Map<String, dynamic>,
    );
    expect(golden.score!.endsSwapped || golden.score!.autoChangeEnds, isFalse);
    expect(golden.endsSwappedAt(58), isFalse);
    const newer = Health(
      version: '0.1.0',
      schemaVersion: '1.7',
      device: 'cpu',
      authRequired: false,
      stages: [],
    );
    const older = Health(
      version: '0.1.0',
      schemaVersion: '1.6',
      device: 'cpu',
      authRequired: false,
      stages: [],
    );
    expect(newer.supportsChangeEnds, isTrue);
    expect(older.supportsChangeEnds, isFalse);
  });

  group('the score at a playback position starts from the session start', () {
    ClipRecord record(Score score, [List<Rally> rallies = const []]) => ClipRecord(
      schemaVersion: '1.7',
      clipId: 'ends',
      fps: 30,
      width: 640,
      height: 360,
      numFrames: 60,
      frames: const [],
      hits: const [],
      rallies: rallies,
      score: score,
    );
    ScoreCorrection ends(int frame, {int rally = 0}) =>
        ScoreCorrection(rallyIndex: rally, kind: 'ends', frame: frame);
    ScoreCorrection award(String side, int frame, {int rally = 0}) =>
        ScoreCorrection(rallyIndex: rally, winnerAfter: side, kind: 'award', frame: frame);
    void at(ClipRecord r, int frame, int near, int far, {required bool swapped}) {
      expect(
        r.scoreAt(frame),
        ScorePair(near: near, far: far),
        reason: 'frame $frame',
      );
      expect(r.endsSwappedAt(frame), swapped, reason: 'frame $frame');
    }

    test('ends changed by hand before the first rally ends', () {
      // 5-3, the players cross at frame 10, then the near end wins rally 0: 4-5.
      final r = record(Score(near: 4, far: 5, endsSwapped: true, corrections: [ends(10)]), const [
        Rally(
          index: 0,
          startFrame: 30,
          endFrame: 40,
          winner: 'near',
          scoreAfter: ScorePair(near: 4, far: 5),
          endsSwapped: true,
        ),
      ]);
      at(r, 5, 5, 3, swapped: false);
      at(r, 20, 3, 5, swapped: true);
      at(r, 45, 4, 5, swapped: true);
      // No rally at all: the final score is the start score as it stands after the change.
      final none = record(Score(near: 3, far: 5, endsSwapped: true, corrections: [ends(10)]));
      at(none, 5, 5, 3, swapped: false);
      at(none, 20, 3, 5, swapped: true);
    });

    test('a point awarded before the first rally goes to the end as it was then', () {
      // 5-3, point near (6-3), the players cross (3-6), point near (4-6), far wins rally 0.
      final r = record(
        Score(
          near: 4,
          far: 7,
          endsSwapped: true,
          corrections: [award('near', 5), ends(10), award('near', 15)],
        ),
        const [
          Rally(
            index: 0,
            startFrame: 30,
            endFrame: 40,
            winner: 'far',
            scoreAfter: ScorePair(near: 4, far: 7),
            endsSwapped: true,
          ),
        ],
      );
      at(r, 2, 5, 3, swapped: false);
      at(r, 7, 6, 3, swapped: false);
      at(r, 12, 3, 6, swapped: true);
      at(r, 20, 4, 6, swapped: true);
      at(r, 45, 4, 7, swapped: true);
    });

    test('awards alone cross a game boundary: the count restarts', () {
      // Best of three from 19-20 with no rally found. Far takes the game (19-21), the players
      // cross by rule, and the next point starts game 2 at the new near end.
      final crossed = record(
        Score(
          near: 1,
          far: 0,
          bestOf: 3,
          game: 2,
          games: const [ScorePair(near: 21, far: 19)],
          gamesWon: const ScorePair(near: 1, far: 0),
          autoChangeEnds: true,
          endsSwapped: true,
          corrections: [award('far', 10), award('near', 20)],
        ),
      );
      at(crossed, 5, 19, 20, swapped: false);
      at(crossed, 15, 21, 19, swapped: true); // the finished game stays up, from the new ends
      at(crossed, 25, 1, 0, swapped: true);
      // After a scored rally, without the automatic change: 20-10, point near wins the game,
      // point far opens game 2.
      final after = record(
        Score(
          near: 0,
          far: 1,
          bestOf: 3,
          game: 2,
          games: const [ScorePair(near: 21, far: 10)],
          gamesWon: const ScorePair(near: 1, far: 0),
          corrections: [award('near', 10, rally: 1), award('far', 20, rally: 1)],
        ),
        const [
          Rally(
            index: 0,
            startFrame: 0,
            endFrame: 5,
            winner: 'near',
            scoreAfter: ScorePair(near: 20, far: 10),
          ),
        ],
      );
      at(after, 2, 19, 10, swapped: false);
      at(after, 7, 20, 10, swapped: false);
      at(after, 12, 21, 10, swapped: false);
      at(after, 25, 0, 1, swapped: false);
      // The match is won: a point awarded after it does not count.
      final won = record(
        Score(
          near: 21,
          far: 10,
          games: const [ScorePair(near: 21, far: 10)],
          gamesWon: const ScorePair(near: 1, far: 0),
          matchWinner: 'near',
          corrections: [award('near', 10, rally: 1), award('far', 20, rally: 1)],
        ),
        const [
          Rally(
            index: 0,
            startFrame: 0,
            endFrame: 5,
            winner: 'near',
            scoreAfter: ScorePair(near: 20, far: 10),
          ),
        ],
      );
      at(won, 12, 21, 10, swapped: false);
      at(won, 25, 21, 10, swapped: false);
    });

    test('an award reaches 11 in a one-game match: the players cross by rule', () {
      // 9-4: two points at the near end (11-4), the players cross (4-11), a point at the far
      // end, where the leader now stands (4-12).
      final r = record(
        Score(
          near: 4,
          far: 12,
          autoChangeEnds: true,
          endsSwapped: true,
          corrections: [award('near', 10), award('near', 20), award('far', 30)],
        ),
      );
      at(r, 5, 9, 4, swapped: false);
      at(r, 15, 10, 4, swapped: false);
      at(r, 25, 4, 11, swapped: true);
      at(r, 35, 4, 12, swapped: true);
    });
  });

  test('a job keeps the change of ends and the games already won for a retry', () {
    final json = <String, dynamic>{
      'id': 'j1',
      'video_id': 'v1',
      'status': 'failed',
      'progress': 0,
      'created_at': '2026-11-16T00:00:00Z',
      'referee': true,
      'best_of': 3,
    };
    final job = Job.fromJson({
      ...json,
      'auto_change_ends': false,
      'start_games': {'near': 1, 'far': 0},
      'game_service': [
        {'game': 2, 'server_id': 'near_1', 'receiver_id': 'far_2'},
      ],
    });
    expect(job.autoChangeEnds, isFalse);
    expect(job.startGames, (near: 1, far: 0));
    expect((job.gameService.single.game, job.gameService.single.serverId), (2, 'near_1'));
    expect(job.options.autoChangeEnds, isFalse);
    expect(job.options.startGames, (near: 1, far: 0));
    expect(job.options.copyWith(overlays: {}).withStrokeModel('rf').startGames, (near: 1, far: 0));
    final on = Job.fromJson({...json, 'auto_change_ends': true});
    expect(on.options.autoChangeEnds, isTrue);
    expect(on.options.startGames, isNull);
    // A job stored before clip record 1.7 has no change of ends, as the server scores it.
    expect(Job.fromJson(json).options.autoChangeEnds, isFalse);
  });
}
