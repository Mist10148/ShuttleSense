/// Small helpers for reading backend JSON without code generation.
typedef Json = Map<String, dynamic>;

double? asDouble(Object? v) => v == null ? null : (v as num).toDouble();

int? asInt(Object? v) => v == null ? null : (v as num).toInt();

DateTime? asDate(Object? v) => v == null ? null : DateTime.parse(v as String);

List<Json> asList(Object? v) => (v as List<dynamic>? ?? const []).cast<Json>();

/// [x, y] pair, or null.
({double x, double y})? asPoint(Object? v) {
  if (v == null) return null;
  final list = v as List<dynamic>;
  return (x: (list[0] as num).toDouble(), y: (list[1] as num).toDouble());
}
