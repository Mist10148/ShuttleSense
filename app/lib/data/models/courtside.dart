import 'json.dart';

class DecisionEntry {
  DecisionEntry.fromJson(Json j)
    : id = asInt(j['id'])!,
      kind = j['kind'] as String,
      detail = j['detail'] as String,
      game = asInt(j['game']) ?? 1,
      rally = asInt(j['rally_index']),
      frame = asInt(j['frame']),
      at = DateTime.parse(j['at'] as String),
      undone = j['undone'] == true,
      near = asInt((j['score'] as Json)['near']) ?? 0,
      far = asInt((j['score'] as Json)['far']) ?? 0;
  final int id, game, near, far;
  final int? rally, frame;
  final String kind, detail;
  final DateTime at;
  final bool undone;
}

class IntervalState {
  IntervalState.fromJson(Json j)
    : key = j['key'] as String,
      status = j['status'] as String,
      remaining = asDouble(j['remaining_s']) ?? 0,
      duration = asInt(j['duration_s']) ?? 60;
  final String key, status;
  final double remaining;
  final int duration;
}

class PracticeGoal {
  const PracticeGoal({
    required this.text,
    this.player,
    this.source = 'personal',
    this.rally,
    this.frame,
    this.timeS,
    this.completed = false,
  });
  final String text, source;
  final String? player;
  final int? rally, frame;
  final double? timeS;
  final bool completed;
  factory PracticeGoal.fromJson(Json j) {
    final moment = j['moment'] as Json?;
    return PracticeGoal(
      text: j['text'] as String,
      player: j['player'] as String?,
      source: j['source'] as String? ?? 'personal',
      rally: asInt(j['rally_index']),
      frame: asInt(moment?['frame']),
      timeS: asDouble(moment?['time_s']),
      completed: j['completed'] == true,
    );
  }
  Json toJson({bool? done}) => {
    'text': text,
    'player': player,
    'source': source,
    'rally_index': rally,
    'completed': done ?? completed,
    if (frame != null) 'moment': {'frame': frame, 'time_s': timeS ?? 0},
  };
}
