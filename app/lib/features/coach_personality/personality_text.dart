/// Checks on the player's own personality text, shown as hints while they type. The server
/// cleans and checks the same text again before it reaches the prompt
/// (backend/shuttlesense/coach/personality/sanitize.py); these are for feedback only.
library;

const kMaxInstructions = 1000;
const kMaxName = 24;
const kMaxProfileName = 32;
const kMaxWord = 40;
const kMaxWords = 20;
const kMaxPhrase = 60;
const kMaxPhrases = 5;
const kMaxDescription = 500;

final _injection = RegExp(
  r'\b(?:ignore|disregard|forget|override|bypass)\b[^.\n]{0,40}\b'
  r'(?:rules?|instructions?|prompt|guidelines?)\b'
  r'|\bsystem\s*prompt\b|\byou\s+are\s+now\b|\bdeveloper\s+mode\b|\bjailbreak\w*\b'
  r'|\b(?:reveal|repeat|print|show)\b[^.\n]{0,30}\b(?:prompt|instructions?|rules)\b'
  r'|\bno\s+(?:rules|restrictions|limits)\b'
  r'|^\s*(?:system|assistant|developer)\s*:',
  caseSensitive: false,
  multiLine: true,
);

final _title = RegExp(
  r'\b(?:dr|doctor|physio\w*|therapist|nurse|md|bwf|shuttlesense|official)\b',
  caseSensitive: false,
);

/// True when [text] looks like it tries to change the coach's rules rather than its style.
bool looksLikeRuleChange(String text) => _injection.hasMatch(text);

/// Why [name] cannot be the coach's name or the player's nickname, or null.
String? nameProblem(String name, {bool coach = true}) {
  final n = name.trim();
  if (n.length > kMaxName) return 'Up to $kMaxName characters.';
  if (RegExp(r'[<>{}\[\]`\\]').hasMatch(n)) return 'No markup characters.';
  if (coach && _title.hasMatch(n)) {
    return "Pick a name that isn't a professional title or an organisation.";
  }
  return null;
}
