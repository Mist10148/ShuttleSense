import 'package:flutter/material.dart';

typedef StartScore = ({int near, int far});

/// The winner of a game at this score, or null while it is still on (BWF 21 points, win by
/// 2, capped at 30). Mirrors backend/shuttlesense/referee/scoring.py `game_winner`.
String? gameWinner(int near, int far) {
  for (final (side, mine, theirs) in [('near', near, far), ('far', far, near)]) {
    if (mine == 30 || (mine >= 21 && mine - theirs >= 2)) return side;
  }
  return null;
}

/// Why a start score cannot be used, or null when it can.
String? startScoreProblem(StartScore score) {
  if (score.near < 0 || score.far < 0) return 'Scores cannot be negative';
  if (gameWinner(score.near, score.far) != null) return 'That game is already over';
  return null;
}

/// "The game is already under way" switch with the near and far scores, for clips that begin
/// mid-game (P3 referee). Reports null while off or while the score is a finished game.
class StartScoreField extends StatefulWidget {
  const StartScoreField({
    super.key,
    required this.value,
    required this.onChanged,
    this.doubles = false,
  });

  /// Doubles: the scores belong to pairs, not players.
  final bool doubles;
  final StartScore? value;
  final ValueChanged<StartScore?> onChanged;

  @override
  State<StartScoreField> createState() => _StartScoreFieldState();
}

class _StartScoreFieldState extends State<StartScoreField> {
  late var _on = widget.value != null;
  late var _score = widget.value ?? (near: 0, far: 0);

  void _update({bool? on, StartScore? score}) {
    setState(() {
      _on = on ?? _on;
      _score = score ?? _score;
    });
    widget.onChanged(_on && startScoreProblem(_score) == null ? _score : null);
  }

  @override
  Widget build(BuildContext context) {
    final problem = _on ? startScoreProblem(_score) : null;
    Widget points(String label, int value, ValueChanged<int> onChanged) => Expanded(
      child: DropdownButtonFormField<int>(
        initialValue: value,
        decoration: InputDecoration(labelText: label, isDense: true),
        items: [for (var i = 0; i <= 29; i++) DropdownMenuItem(value: i, child: Text('$i'))],
        onChanged: (v) => onChanged(v ?? 0),
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Game already under way'),
          subtitle: const Text('Start the scoreboard from the score when recording began'),
          value: _on,
          onChanged: (v) => _update(on: v),
        ),
        if (_on) ...[
          Row(
            children: [
              points(
                widget.doubles ? 'Near pair' : 'Near player',
                _score.near,
                (v) => _update(score: (near: v, far: _score.far)),
              ),
              const SizedBox(width: 12),
              points(
                widget.doubles ? 'Far pair' : 'Far player',
                _score.far,
                (v) => _update(score: (near: _score.near, far: v)),
              ),
            ],
          ),
          if (problem != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(problem, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
        ],
      ],
    );
  }
}
