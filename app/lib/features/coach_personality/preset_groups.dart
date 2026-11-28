/// How Settings > AI Coach groups the built-in presets (docs/coach-personality/ui-ux.md).
///
/// Sixteen look-alike keys are hard to scan, so the card shows four small sets of four,
/// each named for what the voices have in common, with a two- or three-word tagline under
/// every preset. This is presentation only: the presets, and their parity with the server,
/// live in presets.dart. "Custom" is not in a group; the card offers it on its own.
library;

/// One labelled set of presets.
class PresetGroup {
  const PresetGroup({
    required this.id,
    required this.label,
    required this.blurb,
    required this.presetIds,
  });

  final String id;
  final String label;

  /// One line under the heading: what the voices in the group share.
  final String blurb;
  final List<String> presetIds;
}

const kPresetGroups = <PresetGroup>[
  PresetGroup(
    id: 'everyday',
    label: 'Everyday',
    blurb: 'Clear, balanced coaching',
    presetIds: ['default', 'professional', 'efficient', 'reserved'],
  ),
  PresetGroup(
    id: 'supportive',
    label: 'Supportive',
    blurb: 'Warm and encouraging',
    presetIds: ['friendly', 'mentor', 'compassionate', 'cute_shy'],
  ),
  PresetGroup(
    id: 'challenging',
    label: 'Challenging',
    blurb: 'Pushes you and asks why',
    presetIds: ['bold', 'stoic', 'intellectual', 'cynical'],
  ),
  PresetGroup(
    id: 'fun',
    label: 'Fun',
    blurb: 'Playful, inventive, a bit odd',
    presetIds: ['witty', 'playful', 'creative', 'robotic'],
  ),
];

/// A few words under each preset's name, so the grid reads without tooltips.
const kPresetTaglines = <String, String>{
  'default': 'Balanced all-rounder',
  'professional': 'Formal and precise',
  'efficient': 'Short and direct',
  'reserved': 'Calm, quiet care',
  'friendly': 'Warm and upbeat',
  'mentor': 'Step-by-step teacher',
  'compassionate': 'Gentle and reassuring',
  'cute_shy': 'Sweet and bashful',
  'bold': 'Firm motivator',
  'stoic': 'Disciplined focus',
  'intellectual': 'Explains the why',
  'cynical': 'Dry and sharp',
  'witty': 'Clever humour',
  'playful': 'Banter and games',
  'creative': 'Inventive drills',
  'robotic': 'Facts and numbers',
  'custom': 'Sliders and your own words',
};

/// The group a preset belongs to; the first group for Custom or an unknown id.
PresetGroup groupOf(String presetId) => kPresetGroups.firstWhere(
  (g) => g.presetIds.contains(presetId),
  orElse: () => kPresetGroups.first,
);
