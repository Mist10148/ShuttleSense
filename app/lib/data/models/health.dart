import 'json.dart';

/// GET /health (docs/API.md).
class Health {
  const Health({
    this.status = 'ok',
    required this.version,
    required this.schemaVersion,
    required this.device,
    required this.authRequired,
    required this.stages,
    this.strokeModels,
    this.chatAvailable = false,
    this.chatMaxMessages = 0,
  });

  final String status;
  final String version;
  final String schemaVersion;
  final String device;
  final bool authRequired;
  final List<String> stages;

  /// Stroke models installed on the server (cnn, lstm, rf). Null on a server older than clip
  /// record 1.4, which has one model and no choice.
  final List<String>? strokeModels;

  /// The backend has a Claude API key, so the coach chat works.
  final bool chatAvailable;
  final int chatMaxMessages;

  /// The clip record version this app was built against (backend/shuttlesense/schema.py).
  /// Minor versions only add optional fields, so any 1.x backend works.
  static const expectedSchema = '1.5';

  bool get schemaMatches => schemaVersion.split('.').first == expectedSchema.split('.').first;

  bool _atLeast(int minor) {
    final parts = schemaVersion.split('.');
    final major = int.tryParse(parts.first) ?? 0;
    final have = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
    return major > 1 || (major == 1 && have >= minor);
  }

  /// WS /live arrived with clip record 1.1; a 1.0 backend has no live sessions.
  bool get supportsLive => _atLeast(1);

  /// Clip record 1.5 (D33): joining a match under way, decision reasons and retirement.
  bool get supportsCourtside => _atLeast(5);

  /// Whether the backend can produce [overlay] (its stage is installed).
  bool supportsOverlay(String overlay, Map<String, String> overlayStage) {
    final stage = overlayStage[overlay];
    return stage == null || stages.contains(stage);
  }

  factory Health.fromJson(Json j) => Health(
    status: j['status'] as String? ?? 'ok',
    version: j['version'] as String,
    schemaVersion: j['schema_version'] as String,
    device: j['device'] as String,
    authRequired: j['auth_required'] as bool,
    stages: (j['stages'] as List<dynamic>).cast<String>(),
    strokeModels: (j['stroke_models'] as List<dynamic>?)?.cast<String>(),
    chatAvailable: j['chat_available'] as bool? ?? false,
    chatMaxMessages: asInt(j['chat_max_messages']) ?? 0,
  );
}
