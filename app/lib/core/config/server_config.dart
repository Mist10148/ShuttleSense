import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Overridden in main() with the loaded instance.
final sharedPreferencesProvider = Provider<SharedPreferences>(
  (ref) => throw UnimplementedError('sharedPreferencesProvider not overridden'),
);

/// Optional build-time default, e.g. --dart-define=API_BASE_URL=http://192.168.1.20:8000
const String kDefaultBaseUrl = String.fromEnvironment('API_BASE_URL');

/// Where the backend lives (laptop on the LAN or a Colab tunnel) and its token.
class ServerConfig {
  const ServerConfig({required this.baseUrl, this.token});

  final String baseUrl;
  final String? token;

  /// Normalizes user input: trims, adds http:// if missing, drops trailing slashes.
  static String normalizeUrl(String input) {
    var url = input.trim();
    if (url.isEmpty) return url;
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'http://$url';
    }
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }

  /// Error message for an unusable address, or null if it looks valid.
  static String? validateUrl(String input) {
    final url = normalizeUrl(input);
    if (url.isEmpty) return 'Enter the server address';
    final uri = Uri.tryParse(url);
    final badHost = uri == null || uri.host.isEmpty || uri.host == 'http' || uri.host == 'https';
    if (badHost || url.contains(RegExp(r'\s'))) {
      return 'That does not look like an address, e.g. http://192.168.1.20:8000';
    }
    if (uri.hasPort && (uri.port <= 0 || uri.port > 65535)) return 'The port must be 1 to 65535';
    return null;
  }

  /// A page served over https cannot call an http server (mixed content), so a web build
  /// on https needs the https tunnel URL.
  static bool isMixedContent(String pageScheme, String serverUrl) =>
      pageScheme == 'https' && serverUrl.startsWith('http://');
}

class ServerConfigNotifier extends Notifier<ServerConfig?> {
  static const _urlKey = 'server.baseUrl';
  static const _tokenKey = 'server.token';
  static const _recentKey = 'server.recent';
  static const maxRecent = 3;

  SharedPreferences get _prefs => ref.read(sharedPreferencesProvider);

  @override
  ServerConfig? build() {
    final url = _prefs.getString(_urlKey) ?? kDefaultBaseUrl;
    if (url.isEmpty) return null;
    return ServerConfig(baseUrl: url, token: _prefs.getString(_tokenKey));
  }

  /// Last [maxRecent] server addresses, newest first (tokens are not remembered here).
  List<String> get recent => _prefs.getStringList(_recentKey) ?? const [];

  Future<void> save(ServerConfig config) async {
    await _prefs.setString(_urlKey, config.baseUrl);
    await _prefs.setStringList(
      _recentKey,
      [config.baseUrl, ...recent.where((u) => u != config.baseUrl)].take(maxRecent).toList(),
    );
    final token = config.token;
    if (token == null || token.isEmpty) {
      await _prefs.remove(_tokenKey);
    } else {
      await _prefs.setString(_tokenKey, token);
    }
    state = config;
  }

  Future<void> clear() async {
    await _prefs.remove(_urlKey);
    await _prefs.remove(_tokenKey);
    state = null;
  }
}

final serverConfigProvider = NotifierProvider<ServerConfigNotifier, ServerConfig?>(
  ServerConfigNotifier.new,
);
