import 'package:flutter/material.dart';

/// Match settings for the referee layer (D21): one game or the best of three, and who
/// serves first (one camera cannot tell; unknown until a rally is won). [court] is only
/// offered for live sessions, where it picks the lines line calls use.
typedef MatchSetup = ({int bestOf, String? firstServer, String court});

const MatchSetup kDefaultMatchSetup = (bestOf: 1, firstServer: null, court: 'singles');

class MatchSetupField extends StatelessWidget {
  const MatchSetupField({
    super.key,
    required this.value,
    required this.onChanged,
    this.showCourt = false,
  });

  final MatchSetup value;
  final ValueChanged<MatchSetup> onChanged;
  final bool showCourt;

  @override
  Widget build(BuildContext context) {
    final label = Theme.of(context).textTheme.labelLarge;
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
            onSelectionChanged: (s) =>
                onChanged((bestOf: s.first, firstServer: value.firstServer, court: value.court)),
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
            selected: {value.firstServer ?? ''},
            onSelectionChanged: (s) => onChanged((
              bestOf: value.bestOf,
              firstServer: s.first.isEmpty ? null : s.first,
              court: value.court,
            )),
          ),
        ),
        if (showCourt)
          row(
            'Lines',
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'singles', label: Text('Singles')),
                ButtonSegment(value: 'doubles', label: Text('Doubles')),
              ],
              selected: {value.court},
              onSelectionChanged: (s) =>
                  onChanged((bestOf: value.bestOf, firstServer: value.firstServer, court: s.first)),
            ),
          ),
      ],
    );
  }
}
