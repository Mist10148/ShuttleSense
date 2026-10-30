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
    this.chatAvailable = false,
    this.chatMaxMessages = 0,
  });

  final String status;
  final String version;
  final String schemaVersion;
  final String device;
  final bool authRequired;
  final List<String> stages;

  /// The backend has a Claude API key, so the coach chat works.
  final bool chatAvailable;
  final int chatMaxMessages;

  /// The clip record version this app was built against (backend/shuttlesense/schema.py).
  /// Minor versions only add optional fields, so any 1.x backend works.
  static const expectedSchema = '1.1';

  bool get schemaMatches => schemaVersion.split('.').first == expectedSchema.split('.').first;

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
    chatAvailable: j['chat_available'] as bool? ?? false,
    chatMaxMessages: asInt(j['chat_max_messages']) ?? 0,
  );
}
