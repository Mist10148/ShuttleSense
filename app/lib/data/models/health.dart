import 'json.dart';

/// GET /health (docs/API.md).
class Health {
  const Health({
    required this.version,
    required this.schemaVersion,
    required this.device,
    required this.authRequired,
    required this.stages,
  });

  final String version;
  final String schemaVersion;
  final String device;
  final bool authRequired;
  final List<String> stages;

  factory Health.fromJson(Json j) => Health(
    version: j['version'] as String,
    schemaVersion: j['schema_version'] as String,
    device: j['device'] as String,
    authRequired: j['auth_required'] as bool,
    stages: (j['stages'] as List<dynamic>).cast<String>(),
  );
}
