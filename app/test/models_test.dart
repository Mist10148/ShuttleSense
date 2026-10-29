import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuttlesense_app/core/config/server_config.dart';
import 'package:shuttlesense_app/data/models/clip_record.dart';
import 'package:shuttlesense_app/data/models/job.dart';

// Mirrors the example in docs/DATA_FORMAT.md / backend/tests/test_schema.py.
final recordJson = <String, dynamic>{
  'schema_version': '1.0',
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
    expect(golden.hits[1].tip, startsWith('Reach higher'));
    expect(golden.hits[0].tip, isNull);
    expect(golden.hits[2].classProbs['smash'], 0.86);
    // Rallies and the score at a playback position.
    expect(golden.rallies.single.winner, 'near');
    expect(golden.rallies.single.landing!.inCourt, isTrue);
    expect(golden.scoreAt(10), const ScorePair(near: 0, far: 0));
    expect(golden.scoreAt(58), const ScorePair(near: 1, far: 0));
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
}
