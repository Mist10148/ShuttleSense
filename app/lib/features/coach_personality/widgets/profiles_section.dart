import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/tokens.dart';
import '../import_export.dart';
import '../personality_models.dart';
import '../personality_notifier.dart';
import '../personality_switcher_sheet.dart';
import '../personality_text.dart';
import '../presets.dart';

/// Saved personalities: use, edit, rename, duplicate, export, delete, and import or export
/// them all (docs/coach-personality/ui-ux.md, Profiles).
class ProfilesSection extends ConsumerWidget {
  const ProfilesSection({super.key, required this.onEdit, this.enabled = true});

  /// Opens a profile (or a preset) in the editor.
  final ValueChanged<String> onEdit;
  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(personalityProvider);
    final notifier = ref.read(personalityProvider.notifier);
    final text = Theme.of(context).textTheme;
    final full = settings.profiles.length >= PersonalitySettings.maxProfiles;

    Future<void> remove(PersonalityProfile p) async {
      final ok = await _confirm(
        context,
        title: 'Delete "${p.name}"?',
        body: 'You can undo this for a few seconds.',
        action: 'Delete',
      );
      if (!ok) return;
      final removed = await notifier.delete(p.id);
      if (removed == null || !context.mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text('Deleted "${p.name}"'),
            duration: const Duration(seconds: 5),
            action: SnackBarAction(label: 'Undo', onPressed: () => notifier.undoDelete(removed)),
            persist: false,
          ),
        );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (settings.profiles.isEmpty)
          Text(
            'No saved profiles yet. Change any setting above and save to create one.',
            style: text.bodySmall,
          )
        else
          RadioGroup<String>(
            groupValue: settings.activeId,
            onChanged: (id) {
              if (id == null || !enabled) return;
              notifier.activateProfile(id);
              announceCoach(context, settings.profiles.firstWhere((p) => p.id == id).name);
            },
            child: Column(
              children: [
                for (final p in settings.profiles)
                  RadioListTile<String>(
                    key: ValueKey('profile-${p.id}'),
                    value: p.id,
                    enabled: enabled,
                    contentPadding: EdgeInsets.zero,
                    title: Text(p.name),
                    subtitle: Text(
                      '${presetById(p.basePreset).label} · edited'
                      '${p.source == ProfileSource.generated ? ' · AI draft' : ''}'
                      '${p.source == ProfileSource.imported ? ' · imported' : ''}',
                    ),
                    secondary: PopupMenuButton<String>(
                      key: ValueKey('profile-menu-${p.id}'),
                      tooltip: 'More for ${p.name}',
                      enabled: enabled,
                      onSelected: (action) async {
                        switch (action) {
                          case 'edit':
                            onEdit(p.id);
                          case 'rename':
                            final name = await _askName(context, 'Rename profile', p.name);
                            if (name != null) await notifier.rename(p.id, name);
                          case 'duplicate':
                            if (!full) await notifier.duplicate(p.id);
                          case 'export':
                            if (context.mounted) await _showExport(context, [p], settings.global);
                          case 'delete':
                            await remove(p);
                        }
                      },
                      itemBuilder: (_) => [
                        const PopupMenuItem(value: 'edit', child: Text('Edit')),
                        const PopupMenuItem(value: 'rename', child: Text('Rename')),
                        PopupMenuItem(
                          value: 'duplicate',
                          enabled: !full,
                          child: const Text('Duplicate'),
                        ),
                        const PopupMenuItem(value: 'export', child: Text('Export')),
                        const PopupMenuItem(value: 'delete', child: Text('Delete')),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        const SizedBox(height: Spacing.sm),
        Wrap(
          spacing: Spacing.sm,
          runSpacing: Spacing.sm,
          children: [
            Tooltip(
              message: full ? 'You have 20 profiles. Delete one to add another.' : '',
              child: OutlinedButton.icon(
                key: const ValueKey('profile-new'),
                onPressed: enabled && !full
                    ? () async {
                        final start = await _askNew(context);
                        if (start == null) return;
                        final saved = await notifier.saveProfile(
                          notifier.draftFrom(basePreset: start.$2, name: start.$1),
                        );
                        if (saved != null) onEdit(saved.id);
                      }
                    : null,
                icon: const Icon(Icons.add),
                label: const Text('New profile'),
              ),
            ),
            OutlinedButton.icon(
              key: const ValueKey('profile-import'),
              onPressed: enabled && !full ? () => _showImport(context, ref) : null,
              icon: const Icon(Icons.download_outlined),
              label: const Text('Import'),
            ),
            OutlinedButton.icon(
              key: const ValueKey('profile-export-all'),
              onPressed: settings.profiles.isEmpty
                  ? null
                  : () => _showExport(context, settings.profiles, settings.global),
              icon: const Icon(Icons.upload_outlined),
              label: const Text('Export all'),
            ),
          ],
        ),
        const SizedBox(height: Spacing.md),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const ValueKey('personality-reset-all'),
            onPressed: enabled
                ? () async {
                    final ok = await _confirm(
                      context,
                      title: 'Reset all coach personality settings?',
                      body:
                          'Deletes every profile and your names, and goes back to the '
                          'Default coach. This cannot be undone.',
                      action: 'Reset',
                    );
                    if (ok) await notifier.resetAll();
                  }
                : null,
            icon: const Icon(Icons.delete_sweep_outlined),
            label: const Text('Reset all personality settings'),
          ),
        ),
      ],
    );
  }
}

Future<bool> _confirm(
  BuildContext context, {
  required String title,
  required String body,
  required String action,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: Text(action)),
        ],
      ),
    ) ??
    false;

Future<String?> _askName(BuildContext context, String title, String initial) => showDialog<String>(
  context: context,
  builder: (context) => _NameDialog(title: title, initial: initial),
);

/// The new profile's name and the preset it starts from.
Future<(String, String)?> _askNew(BuildContext context) =>
    showDialog<(String, String)>(context: context, builder: (context) => const _NewDialog());

/// Dialogs own their text fields, so a field outlives the dialog's closing animation.
class _NameDialog extends StatefulWidget {
  const _NameDialog({required this.title, required this.initial});

  final String title;
  final String initial;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final _field = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _done() => Navigator.pop(context, _field.text.trim().isEmpty ? null : _field.text.trim());

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(
      key: const ValueKey('profile-name'),
      controller: _field,
      autofocus: true,
      maxLength: kMaxProfileName,
      decoration: const InputDecoration(labelText: 'Name'),
      onSubmitted: (_) => _done(),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      TextButton(
        key: const ValueKey('profile-name-save'),
        onPressed: _done,
        child: const Text('Save'),
      ),
    ],
  );
}

class _NewDialog extends StatefulWidget {
  const _NewDialog();

  @override
  State<_NewDialog> createState() => _NewDialogState();
}

class _NewDialogState extends State<_NewDialog> {
  final _field = TextEditingController(text: 'My coach');
  var _base = 'default';

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('New profile'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          key: const ValueKey('profile-new-name'),
          controller: _field,
          maxLength: kMaxProfileName,
          decoration: const InputDecoration(labelText: 'Name'),
          onChanged: (_) => setState(() {}),
        ),
        DropdownMenu<String>(
          key: const ValueKey('profile-new-base'),
          label: const Text('Start from'),
          initialSelection: _base,
          expandedInsets: EdgeInsets.zero,
          dropdownMenuEntries: [
            for (final p in kPersonalityPresets)
              DropdownMenuEntry(value: p.id, label: p.label, leadingIcon: Icon(p.icon)),
          ],
          onSelected: (v) => setState(() => _base = v ?? _base),
        ),
      ],
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      TextButton(
        key: const ValueKey('profile-new-create'),
        onPressed: _field.text.trim().isEmpty
            ? null
            : () => Navigator.pop(context, (_field.text.trim(), _base)),
        child: const Text('Create'),
      ),
    ],
  );
}

Future<void> _showExport(
  BuildContext context,
  List<PersonalityProfile> profiles,
  CoachIdentity global,
) => showDialog<void>(
  context: context,
  builder: (context) {
    var withNames = false;
    return StatefulBuilder(
      builder: (context, setState) {
        final json = exportProfiles(profiles, global: withNames ? global : null);
        return AlertDialog(
          title: Text(profiles.length == 1 ? 'Export "${profiles.single.name}"' : 'Export all'),
          content: SizedBox(
            width: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                CheckboxListTile(
                  key: const ValueKey('export-names'),
                  contentPadding: EdgeInsets.zero,
                  value: withNames,
                  onChanged: (v) => setState(() => withNames = v ?? false),
                  title: const Text('Include names and language'),
                  subtitle: const Text('Includes what the coach calls you.'),
                ),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 240),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      json,
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
            FilledButton.icon(
              key: const ValueKey('export-copy'),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: json));
                if (context.mounted) {
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Copied. Paste it anywhere to keep it.')),
                  );
                }
              },
              icon: const Icon(Icons.copy),
              label: const Text('Copy'),
            ),
          ],
        );
      },
    );
  },
);

Future<void> _showImport(BuildContext context, WidgetRef ref) =>
    showDialog<void>(context: context, builder: (context) => const _ImportDialog());

class _ImportDialog extends ConsumerStatefulWidget {
  const _ImportDialog();

  @override
  ConsumerState<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends ConsumerState<_ImportDialog> {
  final _field = TextEditingController();
  ImportPreview? _preview;

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _read() => setState(() => _preview = previewImport(_field.text));

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final preview = _preview;
    final count = preview?.profiles.length ?? 0;
    return AlertDialog(
      title: const Text('Import profiles'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Paste an exported personality file.', style: text.bodySmall),
              const SizedBox(height: Spacing.sm),
              TextField(
                key: const ValueKey('import-text'),
                controller: _field,
                minLines: 4,
                maxLines: 8,
                decoration: const InputDecoration(labelText: 'Personality file'),
                onChanged: (_) => setState(() => _preview = null),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const ValueKey('import-paste'),
                  onPressed: () async {
                    final data = await Clipboard.getData(Clipboard.kTextPlain);
                    if (data?.text != null) {
                      _field.text = data!.text!;
                      _read();
                    }
                  },
                  icon: const Icon(Icons.paste),
                  label: const Text('Paste'),
                ),
              ),
              if (preview != null) ...[
                if (preview.error != null)
                  Text(
                    preview.error!,
                    key: const ValueKey('import-error'),
                    style: text.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.error),
                  )
                else ...[
                  Text(
                    '$count profile${count == 1 ? '' : 's'} will be added:',
                    style: text.titleSmall,
                  ),
                  for (final p in preview.profiles)
                    Text(
                      '• ${p.name} (${presetById(p.basePreset).label})'
                      '${preview.flagged.contains(p) ? ': some instructions will be ignored' : ''}',
                      style: text.bodySmall,
                    ),
                  for (final s in preview.skipped) Text('Left out: $s', style: text.bodySmall),
                ],
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        if (preview == null)
          TextButton(
            key: const ValueKey('import-check'),
            onPressed: _field.text.trim().isEmpty ? null : _read,
            child: const Text('Check'),
          )
        else
          FilledButton(
            key: const ValueKey('import-add'),
            onPressed: count == 0
                ? null
                : () async {
                    final added = await ref
                        .read(personalityProvider.notifier)
                        .addProfiles(preview.profiles);
                    if (!context.mounted) return;
                    Navigator.pop(context);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Added $added profile${added == 1 ? '' : 's'}.')),
                    );
                  },
            child: const Text('Add'),
          ),
      ],
    );
  }
}
