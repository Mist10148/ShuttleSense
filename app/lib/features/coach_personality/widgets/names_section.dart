import 'package:flutter/material.dart';

import '../../../core/theme/tokens.dart';
import '../../../shared/widgets/tactile.dart';
import '../personality_models.dart';
import '../personality_text.dart';

/// The coach's name and pronouns, what it calls the player, and the reply language. They are
/// shared by every profile unless a profile sets its own
/// (docs/coach-personality/communication-preferences.md, Identity).
class NamesSection extends StatefulWidget {
  const NamesSection({
    super.key,
    required this.global,
    required this.own,
    required this.addressByName,
    required this.onGlobal,
    required this.onOwn,
    required this.onAddressByName,
    this.enabled = true,
  });

  final CoachIdentity global;

  /// The profile's own identity; null means it uses [global].
  final CoachIdentity? own;
  final bool addressByName;
  final ValueChanged<CoachIdentity> onGlobal;
  final ValueChanged<CoachIdentity?> onOwn;
  final ValueChanged<bool> onAddressByName;
  final bool enabled;

  @override
  State<NamesSection> createState() => _NamesSectionState();
}

class _NamesSectionState extends State<NamesSection> {
  late final _coach = TextEditingController(text: _shown.coachName ?? '');
  late final _nick = TextEditingController(text: _shown.playerNickname ?? '');

  bool get _shared => widget.own == null;
  CoachIdentity get _shown => widget.own ?? widget.global;

  @override
  void dispose() {
    _coach.dispose();
    _nick.dispose();
    super.dispose();
  }

  void _set(CoachIdentity next) => _shared ? widget.onGlobal(next) : widget.onOwn(next);

  String? _orNull(String v) => v.trim().isEmpty ? null : v.trim();

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final id = _shown;
    final coachError = nameProblem(_coach.text);
    final nickError = nameProblem(_nick.text, coach: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CheckboxListTile(
          key: const ValueKey('names-shared'),
          contentPadding: EdgeInsets.zero,
          value: _shared,
          title: const Text('Use for all profiles'),
          subtitle: const Text('Off: this profile has its own names and language.'),
          onChanged: !widget.enabled
              ? null
              : (shared) => widget.onOwn(shared == true ? null : widget.global),
        ),
        const SizedBox(height: Spacing.sm),
        TextField(
          key: const ValueKey('names-coach'),
          controller: _coach,
          enabled: widget.enabled,
          maxLength: kMaxName,
          decoration: InputDecoration(
            labelText: "Coach's name",
            hintText: 'Coach',
            errorText: coachError,
            helperText: 'The chat shows it with an AI badge.',
          ),
          onChanged: (v) {
            setState(() {});
            if (nameProblem(v) == null) _set(id.copyWith(coachName: () => _orNull(v)));
          },
        ),
        const SizedBox(height: Spacing.sm),
        DropdownMenu<String>(
          key: const ValueKey('names-pronouns'),
          enabled: widget.enabled,
          label: const Text("Coach's pronouns"),
          expandedInsets: EdgeInsets.zero,
          initialSelection: id.coachPronouns ?? '',
          dropdownMenuEntries: [
            const DropdownMenuEntry(value: '', label: 'Not set'),
            for (final p in kCoachPronouns) DropdownMenuEntry(value: p, label: p),
          ],
          onSelected: (v) => _set(id.copyWith(coachPronouns: () => (v ?? '').isEmpty ? null : v)),
        ),
        const SizedBox(height: Spacing.md),
        TextField(
          key: const ValueKey('names-nickname'),
          controller: _nick,
          enabled: widget.enabled,
          maxLength: kMaxName,
          decoration: InputDecoration(
            labelText: 'What the coach calls you',
            errorText: nickError,
            helperText: 'Sent to the AI provider with your questions.',
          ),
          onChanged: (v) {
            setState(() {});
            if (nameProblem(v, coach: false) == null) {
              _set(id.copyWith(playerNickname: () => _orNull(v)));
            }
          },
        ),
        TactileSwitchTile(
          key: const ValueKey('names-address'),
          title: const Text('Address me by name'),
          subtitle: const Text('Now and then, not in every message.'),
          value: widget.addressByName,
          onChanged: widget.enabled ? widget.onAddressByName : null,
          contentPadding: EdgeInsets.zero,
        ),
        const SizedBox(height: Spacing.sm),
        DropdownMenu<String>(
          key: const ValueKey('names-language'),
          enabled: widget.enabled,
          label: const Text('Reply language'),
          expandedInsets: EdgeInsets.zero,
          initialSelection: id.language ?? 'auto',
          dropdownMenuEntries: [
            for (final e in kCoachLanguages.entries)
              DropdownMenuEntry(value: e.key, label: e.value),
          ],
          onSelected: (v) => _set(id.copyWith(language: () => v == 'auto' ? null : v)),
        ),
        const SizedBox(height: Spacing.xs),
        Text(
          'The badminton notes the coach cites are in English, so other languages are '
          'translated as it answers.',
          style: text.bodySmall,
        ),
      ],
    );
  }
}
