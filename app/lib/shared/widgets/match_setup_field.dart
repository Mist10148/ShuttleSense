import 'package:flutter/material.dart';

import '../../data/models/clip_record.dart';
import '../../data/models/match_setup.dart';

export '../../data/models/match_setup.dart';

/// The match settings form (best of, first server, court, doubles service order).
class MatchSetupField extends StatelessWidget {
  const MatchSetupField({
    super.key,
    required this.value,
    required this.onChanged,
    this.showCourt = false,
    this.showChangeEnds = false,
  });

  final MatchSetup value;
  final ValueChanged<MatchSetup> onChanged;
  final bool showCourt;

  /// The change-of-ends switch, for servers that follow the players (clip record 1.7).
  final bool showChangeEnds;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = theme.textTheme.labelLarge;
    Widget row(String title, Widget control) => Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 12,
        runSpacing: 4,
        children: [
          Text(title, style: label),
          control,
        ],
      ),
    );
    final server = value.firstServer;
    final receiverSide = server == 'near' ? 'far' : 'near';
    String sideName(String side) => playerLabel(side);
    Widget partner({
      required String side,
      required String? selected,
      required ValueChanged<String?> onSelected,
    }) => DropdownButton<String?>(
      value: selected,
      hint: const Text('Not sure'),
      items: [
        const DropdownMenuItem<String?>(value: null, child: Text('Not sure')),
        for (final n in const [1, 2])
          DropdownMenuItem<String?>(
            value: '${side}_$n',
            child: Text('${sideName(side)} player $n'),
          ),
      ],
      onChanged: onSelected,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        row(
          'Match',
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 1, label: Text('1 game')),
              ButtonSegment(value: 3, label: Text('Best of 3')),
            ],
            selected: {value.bestOf},
            onSelectionChanged: (s) => onChanged(value.withBestOf(s.first)),
          ),
        ),
        row(
          'First server',
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: '', label: Text('Unknown')),
              ButtonSegment(value: 'near', label: Text('Near')),
              ButtonSegment(value: 'far', label: Text('Far')),
            ],
            selected: {server ?? ''},
            onSelectionChanged: (s) =>
                onChanged(value.withFirstServer(s.first.isEmpty ? null : s.first)),
          ),
        ),
        if (showChangeEnds) ...[
          row(
            'Change ends',
            Switch(
              key: const Key('auto-change-ends'),
              value: value.autoChangeEnds,
              onChanged: (on) => onChanged(value.withAutoChangeEnds(on)),
            ),
          ),
          Text(
            value.autoChangeEnds
                ? 'By the rules: after each game, and at 11 in the deciding or only game. '
                      'The score moves with the players.'
                : 'Off: the score stays with each end. Use Players changed ends when they '
                      'cross.',
            style: theme.textTheme.bodySmall,
          ),
        ],
        if (showCourt)
          row(
            'Lines',
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'singles', label: Text('Singles')),
                ButtonSegment(value: 'doubles', label: Text('Doubles')),
              ],
              selected: {value.court},
              onSelectionChanged: (s) => onChanged(value.withCourt(s.first)),
            ),
          ),
        if (showCourt && value.doubles && server != null) ...[
          row(
            'Serves first',
            partner(
              side: server,
              selected: value.firstServerId,
              onSelected: (id) =>
                  onChanged(value.withService(serverId: id, receiverId: value.firstReceiverId)),
            ),
          ),
          row(
            'Receives first',
            partner(
              side: receiverSide,
              selected: value.firstReceiverId,
              onSelected: (id) =>
                  onChanged(value.withService(serverId: value.firstServerId, receiverId: id)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'Player 1 is the one on the left when play starts. With both set, the app '
              'follows who serves and receives each rally.',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ],
    );
  }
}
