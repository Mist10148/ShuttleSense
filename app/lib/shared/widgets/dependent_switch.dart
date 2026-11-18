import 'package:flutter/material.dart';

import 'helper_text.dart';

/// A switch that only works while another setting is on. With [blockedBy] set it is
/// greyed out and says what to turn on ("Turn on Calibrate court to enable").
class DependentSwitch extends StatelessWidget {
  const DependentSwitch({
    super.key,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
    this.blockedBy,
  });

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  /// The setting that must be on first, or null when this one can be changed.
  final String? blockedBy;

  @override
  Widget build(BuildContext context) => SwitchListTile(
    contentPadding: EdgeInsets.zero,
    title: Text(title),
    subtitle: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [Text(subtitle), if (blockedBy != null) HelperText('Turn on $blockedBy to enable')],
    ),
    value: value && blockedBy == null,
    onChanged: blockedBy == null ? onChanged : null,
  );
}
