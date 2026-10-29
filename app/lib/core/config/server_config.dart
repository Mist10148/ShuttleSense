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
}

class ServerConfigNotifier extends Notifier<ServerConfig?> {
  static const _urlKey = 'server.baseUrl';
  static const _tokenKey = 'server.token';

  SharedPreferences get _prefs => ref.read(sharedPreferencesProvider);

  @override
  ServerConfig? build() {
    final url = _prefs.getString(_urlKey) ?? kDefaultBaseUrl;
    if (url.isEmpty) return null;
    return ServerConfig(baseUrl: url, token: _prefs.getString(_tokenKey));
  }

  Future<void> save(ServerConfig config) async {
    await _prefs.setString(_urlKey, config.baseUrl);
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
