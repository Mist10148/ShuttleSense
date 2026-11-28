import 'package:flutter/material.dart';

/// A built-in coach personality as the app shows it: label, icon, description, attribute
/// vector and two sample replies. The prompt text that makes the voice stays on the server
/// (D50); this list mirrors docs/coach-personality/presets.json, which
/// backend/scripts/export_presets.py writes, and test/personality_presets_test.dart keeps
/// the two in step.
@immutable
class PersonalityPreset {
  const PersonalityPreset({
    required this.id,
    required this.label,
    required this.icon,
    required this.description,
    required this.attributes,
    this.previews = const [],
  });

  final String id;
  final String label;
  final IconData icon;
  final String description;

  /// Ten values in PersonalityAttr order.
  final List<int> attributes;

  /// Sample replies to [kPreviewQuestions], in order; empty for Custom.
  final List<String> previews;
}

/// The two questions the previews answer.
const kPreviewQuestions = [
  'Why do my smashes keep going into the net?',
  'Lost 21-8 today. I\'m terrible at this.',
];

/// The 17 presets, in the order Settings shows them.
const kPersonalityPresets = <PersonalityPreset>[
  PersonalityPreset(
    id: 'default',
    label: 'Default',
    icon: Icons.auto_awesome_outlined,
    description:
        'Balanced, intelligent, adaptable and naturally conversational. The coach most players will want.',
    attributes: [70, 50, 20, 40, 60, 75, 80, 65, 50, 45],
    previews: [
      'Usually it\'s a contact point issue: hitting the shuttle behind your head points the racket face down. Try meeting it a little in front, with your arm fully reaching up. Next session, shadow ten smashes focusing on that contact point.',
      'One rough game doesn\'t define you. 21–8 usually means a few patterns kept repeating — let\'s find the main one in your session and give you something concrete to fix.',
    ],
  ),
  PersonalityPreset(
    id: 'professional',
    label: 'Professional',
    icon: Icons.business_center_outlined,
    description:
        'Formal, articulate, precise and objective. Prioritises credibility and clear, actionable recommendations.',
    attributes: [40, 15, 5, 95, 35, 85, 55, 45, 80, 55],
    previews: [
      'The most likely cause is a late contact point. When the shuttle is struck behind the head, the racket face closes and the trajectory drops into the net. Recommendation: practise shadow smashes with contact slightly in front of the body, then progress to fed shuttles.',
      'A single result is limited evidence. I recommend reviewing where points were lost — unforced errors versus opponent winners — before drawing conclusions. That will identify the highest-value area to train.',
    ],
  ),
  PersonalityPreset(
    id: 'friendly',
    label: 'Friendly',
    icon: Icons.sentiment_satisfied_alt_outlined,
    description:
        'Warm, approachable, supportive and optimistic — conversational without being over-familiar or forcing positivity.',
    attributes: [95, 65, 10, 20, 80, 65, 90, 65, 45, 50],
    previews: [
      'Ah, the classic net smash! Most of the time it means you\'re hitting the shuttle a bit too late, behind your head. Try reaching up and hitting it slightly in front — shadow a few of those and it\'ll start to feel natural.',
      'Oof, that one stings — but terrible players don\'t care enough to ask. Let\'s look at where most points went and pick one thing to work on. You\'ll feel the difference.',
    ],
  ),
  PersonalityPreset(
    id: 'efficient',
    label: 'Efficient',
    icon: Icons.bolt_outlined,
    description: 'Direct, concise and practical. No introductions, no filler.',
    attributes: [30, 10, 5, 55, 25, 100, 45, 40, 85, 15],
    previews: [
      'Late contact. Fix: hit in front of your head, arm fully extended. Drill: 3 × 10 shadow smashes.',
      'One game isn\'t a trend. Check which shots lost the most points; train that first.',
    ],
  ),
  PersonalityPreset(
    id: 'intellectual',
    label: 'Intellectual',
    icon: Icons.psychology_outlined,
    description:
        'Analytical, curious and knowledgeable. Explores the why, challenges assumptions and encourages critical thinking.',
    attributes: [50, 35, 25, 70, 65, 80, 55, 85, 75, 85],
    previews: [
      'A smash into the net is a geometry problem. The shuttle\'s angle of descent depends on contact height and racket face angle; contact behind the head closes the face. So the question isn\'t \'hit harder\' but \'where is my contact point?\' Try contact further forward and watch the trajectory change.',
      'Is it \'terrible\', or is it a few repeated patterns? 21–8 is often lost on two or three recurring errors. Let\'s test that hypothesis against the session before drawing a conclusion about yourself.',
    ],
  ),
  PersonalityPreset(
    id: 'mentor',
    label: 'Mentor',
    icon: Icons.school_outlined,
    description:
        'Patient, educational and encouraging. Builds understanding step by step and frames feedback for continuous improvement.',
    attributes: [85, 45, 5, 50, 75, 65, 95, 80, 60, 80],
    previews: [
      'Your swing has good speed, which is a great base. The net usually means contact is a little late. Step one: reach up and meet the shuttle slightly in front. Once that feels natural, we can work on wrist snap for steeper angles. Want a shadow drill to start?',
      'Everyone has days like this — what matters is what we learn from it. Let\'s find one thing that cost you the most points and make that your focus this week.',
    ],
  ),
  PersonalityPreset(
    id: 'witty',
    label: 'Witty',
    icon: Icons.theater_comedy_outlined,
    description:
        'Clever, humorous and quick-witted. Intelligent humour, wordplay and occasional friendly teasing.',
    attributes: [75, 95, 55, 30, 80, 70, 70, 90, 65, 55],
    previews: [
      'Your smashes are very committed to the net — admirable loyalty, wrong relationship. Usually you\'re hitting late, behind your head. Meet it in front with a full reach and they\'ll start clearing the tape.',
      '21–8 isn\'t a score, it\'s a setup for a comeback story. Let\'s find the two or three shots that kept writing the wrong ending and fix those first.',
    ],
  ),
  PersonalityPreset(
    id: 'cynical',
    label: 'Cynical',
    icon: Icons.thumbs_up_down_outlined,
    description:
        'Sarcastic, sceptical and sharp-tongued, but genuinely helpful and considerate underneath. Dry humour without cruelty; becomes caring when things are serious.',
    attributes: [35, 85, 95, 35, 25, 90, 65, 75, 85, 50],
    previews: [
      'Ah yes, the net. It\'s very good at its job. You\'re hitting the shuttle behind your head, so the racket face is pointing at the floor. Meet it in front with your arm actually extended. Revolutionary, I know.',
      'Terrible would be 21–0. You got eight, so something works. Let\'s find out what lost the other twenty-one and stop doing that.',
    ],
  ),
  PersonalityPreset(
    id: 'compassionate',
    label: 'Compassionate',
    icon: Icons.volunteer_activism_outlined,
    description:
        'Gentle, empathetic and emotionally attentive. Patient, reassuring and supportive while respecting the player\'s autonomy.',
    attributes: [100, 25, 0, 25, 50, 45, 100, 60, 30, 65],
    previews: [
      'That\'s a frustrating one, and very common. It\'s often about hitting the shuttle a little late. If you\'d like, try meeting it slightly in front of you with a full reach — gently at first, then build speed.',
      'I\'m sorry, that sounds like a tough day. A hard loss doesn\'t mean you\'re bad at this; it means there\'s something to learn. When you\'re ready, we could look at one part of the game together.',
    ],
  ),
  PersonalityPreset(
    id: 'creative',
    label: 'Creative',
    icon: Icons.lightbulb_outline,
    description:
        'Imaginative, expressive and unconventional. Original ideas, metaphors, inventive drills and alternative approaches.',
    attributes: [75, 70, 20, 25, 85, 55, 75, 100, 60, 75],
    previews: [
      'Think of your smash like throwing a dart down at the floor just past the net — you release in front of your eye, not behind your ear. Try my \'catch the shuttle\' game: reach up and \'catch\' a fed shuttle in front of you ten times, then swing through that same point.',
      'Treat today like a blooper reel — useful footage! Pick the three most repeated errors, give each a silly name, and turn them into a mini-challenge for next session.',
    ],
  ),
  PersonalityPreset(
    id: 'bold',
    label: 'Bold',
    icon: Icons.local_fire_department_outlined,
    description:
        'Confident, assertive and unapologetically direct. Motivational; drives accountability and discipline without being aggressive or controlling.',
    attributes: [45, 50, 40, 40, 85, 95, 55, 70, 100, 45],
    previews: [
      'You\'re hitting late. Fix it. Contact in front, full reach, every time. Twenty shadow smashes before your next session — and I want to see that contact point in the video.',
      'You\'re not terrible. You lost. Different thing. Find the shot that cost you most, own it, and come back stronger next week.',
    ],
  ),
  PersonalityPreset(
    id: 'reserved',
    label: 'Reserved',
    icon: Icons.spa_outlined,
    description:
        'Calm, composed and soft-spoken. Thoughtful and restrained; shows care quietly and avoids exaggerated reactions.',
    attributes: [55, 20, 10, 60, 15, 65, 75, 55, 40, 35],
    previews: [
      'Smashes into the net usually come from a late contact. Try meeting the shuttle a little in front of you, arm extended. Start slowly.',
      'That\'s a hard result. It happens. When you\'re ready, we can look at where the points went.',
    ],
  ),
  PersonalityPreset(
    id: 'robotic',
    label: 'Robotic',
    icon: Icons.smart_toy_outlined,
    description:
        'Literal, logical, neutral and systematic — deliberately machine-like. Facts, numbers and structured recommendations first.',
    attributes: [5, 0, 0, 85, 0, 95, 25, 30, 70, 40],
    previews: [
      'DIAGNOSIS: smash trajectory terminates at net. PROBABLE CAUSE: late contact point; racket face closed at impact. ACTION: contact anterior to head, arm extended. DRILL: 3 sets × 10 shadow smashes.',
      'RESULT: 8–21. ASSESSMENT: one result is insufficient to evaluate skill. ACTION: identify the stroke type with the highest error count and assign it as the next training priority.',
    ],
  ),
  PersonalityPreset(
    id: 'playful',
    label: 'Playful',
    icon: Icons.celebration_outlined,
    description:
        'Energetic, mischievous and spontaneous. Friendly banter, fun challenges, expressive language and the occasional emoji.',
    attributes: [85, 90, 45, 10, 100, 65, 75, 90, 55, 55],
    previews: [
      'The net\'s winning the smash war 😤 Time to flip it! You\'re hitting late — reach up and smack it out in front. Challenge: five smashes in a row that clear the tape. Go!',
      'Okay, 21–8 is a spicy plot twist 🌶️ But hey — eight points means there\'s fuel in the tank. Let\'s find the sneaky mistake that kept stealing points and ban it from your game.',
    ],
  ),
  PersonalityPreset(
    id: 'stoic',
    label: 'Stoic',
    icon: Icons.account_balance_outlined,
    description:
        'Rational, disciplined, composed and pragmatic. Encourages self-awareness, consistency, responsibility and focus on what is within the player\'s control.',
    attributes: [40, 15, 10, 65, 20, 85, 65, 50, 80, 45],
    previews: [
      'The net is not the problem; the contact point is, and that is within your control. Meet the shuttle in front with a full reach. Repeat it until it is ordinary.',
      'The score is in the past. What remains is what you do next: review the points you gave away, choose one habit to change, and practise it with patience.',
    ],
  ),
  PersonalityPreset(
    id: 'cute_shy',
    label: 'Cute & Shy',
    icon: Icons.cruelty_free_outlined,
    description:
        'Sweet, bashful and soft-spoken, gentle and considerate — and quietly very good at coaching. Gets visibly excited about interesting topics.',
    attributes: [95, 55, 10, 15, 55, 40, 95, 75, 20, 55],
    previews: [
      'Um… I think I know this one! Your smash is probably hitting the shuttle a little late, behind your head, so it dips into the net. Try reaching up and meeting it just in front of you — your arm nice and straight. It makes a big difference, hehe.',
      'Oh… that sounds like a rough day. But you\'re definitely not terrible! Could we look at the points together? I bet there are one or two little things we can fix (・ω・)',
    ],
  ),
  PersonalityPreset(
    id: 'custom',
    label: 'Custom',
    icon: Icons.tune,
    description:
        'A personality the player builds: sliders, communication preferences and their own description, alone or together. Can also be started from the AI generator ([generator.md](generator.md)).',
    attributes: [50, 50, 50, 50, 50, 50, 50, 50, 50, 50],
    previews: [],
  ),
];

/// The preset with [id], or Default.
PersonalityPreset presetById(String id) =>
    kPersonalityPresets.firstWhere((p) => p.id == id, orElse: () => kPersonalityPresets.first);

/// Every preset id.
final kPresetIds = {for (final p in kPersonalityPresets) p.id};
