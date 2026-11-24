import 'package:flutter/material.dart';

import '../../core/theme/tokens.dart';
import '../../data/models/court_view.dart';

/// Doubles (D23): once a game is won, the winners choose who serves first in the next game,
/// so the app asks. The game winner's side serves; with both chosen the service order is
/// followed for the rest of that game.
class GameServicePrompt extends StatefulWidget {
  const GameServicePrompt({
    super.key,
    required this.game,
    required this.servingSide,
    required this.onSet,
    this.busy = false,
  });

  /// The game that has just started (2 or 3).
  final int game;

  /// The side that won the last game and so serves first.
  final String servingSide;
  final void Function(int game, String serverId, String receiverId) onSet;
  final bool busy;

  @override
  State<GameServicePrompt> createState() => _GameServicePromptState();
}

class _GameServicePromptState extends State<GameServicePrompt> {
  String? _server;
  String? _receiver;

  @override
  void didUpdateWidget(GameServicePrompt old) {
    super.didUpdateWidget(old);
    if (old.game != widget.game || old.servingSide != widget.servingSide) {
      _server = _receiver = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final receiving = widget.servingSide == 'near' ? 'far' : 'near';
    Widget pick(String label, String side, String? value, ValueChanged<String?> onChanged) => Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      children: [
        Text(label, style: theme.textTheme.labelLarge),
        DropdownButton<String?>(
          value: value,
          hint: const Text('Choose'),
          items: [
            for (final n in const [1, 2])
              DropdownMenuItem<String?>(
                value: '${side}_$n',
                child: Text(context.sideLabel('${side}_$n')),
              ),
          ],
          onChanged: widget.busy ? null : onChanged,
        ),
      ],
    );
    return Card(
      margin: const EdgeInsets.only(top: Spacing.sm),
      child: Padding(
        padding: const EdgeInsets.all(Spacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Who serves first in game ${widget.game}?', style: theme.textTheme.titleSmall),
            const SizedBox(height: Spacing.xs),
            Text(
              '${context.sideLabel(widget.servingSide)} won the game and serves first. Pick the '
              'server and receiver so the app can follow the service order.',
              style: theme.textTheme.bodySmall,
            ),
            pick('Serves', widget.servingSide, _server, (v) => setState(() => _server = v)),
            pick('Receives', receiving, _receiver, (v) => setState(() => _receiver = v)),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: widget.busy || _server == null || _receiver == null
                    ? null
                    : () => widget.onSet(widget.game, _server!, _receiver!),
                child: const Text('Set service'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
