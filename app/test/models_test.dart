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
}
