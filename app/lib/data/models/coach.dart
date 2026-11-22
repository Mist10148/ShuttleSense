import 'clip_record.dart';
import 'json.dart';

/// A knowledge-base chunk the coach cited, e.g. kb:footwork#split-step (docs/API.md).
class CoachSource {
  const CoachSource({
    required this.id,
    required this.title,
    this.excerpt,
    this.reference,
    this.edition,
    this.url,
  });

  final String id;
  final String title;

  final String? excerpt, reference, edition, url;

  factory CoachSource.fromJson(Json j) => CoachSource(
    id: j['id'] as String,
    title: j['title'] as String? ?? j['id'] as String,
    excerpt: j['excerpt'] as String?,
    reference: j['reference'] as String?,
    edition: j['edition'] as String?,
    url: j['url'] as String?,
  );

  static List<CoachSource> listFrom(Object? v) =>
      asList(v).map(CoachSource.fromJson).toList(growable: false);
}

class CoachWeakness {
  const CoachWeakness({
    required this.title,
    required this.evidence,
    this.moments = const [],
    this.drill,
  });

  final String title;
  final String evidence;

  /// Seconds into the video, each one a moment of the session.
  final List<double> moments;
  final String? drill;

  /// Tap-to-seek moments; [fps] turns the times into frames.
  List<Moment> momentsAt(double fps) => [
    for (final t in moments) Moment(frame: (t * (fps == 0 ? 30 : fps)).round(), timeS: t),
  ];

  factory CoachWeakness.fromJson(Json j) => CoachWeakness(
    title: j['title'] as String? ?? '',
    evidence: j['evidence'] as String? ?? '',
    moments: [for (final t in (j['moments'] as List<dynamic>? ?? const [])) (t as num).toDouble()],
    drill: j['drill'] as String?,
  );
}

class CoachDrill {
  const CoachDrill({required this.name, required this.purpose, required this.how, this.kbSource});

  final String name;
  final String purpose;
  final String how;
  final String? kbSource;

  factory CoachDrill.fromJson(Json j) => CoachDrill(
    name: j['name'] as String? ?? '',
    purpose: j['purpose'] as String? ?? '',
    how: j['how'] as String? ?? '',
    kbSource: j['kb_source'] as String?,
  );
}

/// GET /jobs/{id}/coach/report (D42).
class CoachReport {
  const CoachReport({
    required this.summary,
    this.strengths = const [],
    this.weaknesses = const [],
    this.drills = const [],
    this.nextSessionGoals = const [],
    this.generatedBy = 'rules',
  });

  final String summary;
  final List<String> strengths;
  final List<CoachWeakness> weaknesses;
  final List<CoachDrill> drills;
  final List<String> nextSessionGoals;

  /// gemini, claude or rules (built from the session notes, no AI).
  final String generatedBy;

  bool get fromRules => generatedBy == 'rules';

  factory CoachReport.fromJson(Json j) => CoachReport(
    summary: j['summary'] as String? ?? '',
    strengths: (j['strengths'] as List<dynamic>? ?? const []).cast<String>(),
    weaknesses: asList(j['weaknesses']).map(CoachWeakness.fromJson).toList(),
    drills: asList(j['drills']).map(CoachDrill.fromJson).toList(),
    nextSessionGoals: (j['next_session_goals'] as List<dynamic>? ?? const []).cast<String>(),
    generatedBy: j['generated_by'] as String? ?? 'rules',
  );
}
