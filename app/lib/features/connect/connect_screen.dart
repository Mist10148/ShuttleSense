import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config/server_config.dart';
import '../../core/router/app_router.dart';
import '../../data/api_client.dart';
import '../../data/models/health.dart';
import '../../shared/widgets/page_scaffold.dart';

/// Checks a server before it is saved; replaced in widget tests.
typedef HealthCheck = Future<Health> Function(ServerConfig config);

final healthCheckProvider = Provider<HealthCheck>(
  (ref) => (config) async {
    final api = ApiClient(config);
    try {
      final health = await api.health();
      // /health is public, so make one authenticated call to catch a mistyped token now
      // rather than on the first upload.
      if (health.authRequired && (config.token?.isNotEmpty ?? false)) {
        await api.listJobs(limit: 1);
      }
      return health;
    } finally {
      api.close();
    }
  },
);

/// C1 / FR-C1: enter the backend URL and optional token, check /health, save.
class ConnectScreen extends ConsumerStatefulWidget {
  const ConnectScreen({super.key});

  @override
  ConsumerState<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends ConsumerState<ConnectScreen> {
  late final TextEditingController _url;
  late final TextEditingController _token;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final saved = ref.read(serverConfigProvider);
    _url = TextEditingController(text: saved?.baseUrl ?? kDefaultBaseUrl);
    _token = TextEditingController(text: saved?.token ?? '');
  }

  @override
  void dispose() {
    _url.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<bool> _confirmSchema(Health health) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Different data format'),
          content: Text(
            'The server sends clip record version ${health.schemaVersion}, but this app '
            'expects ${Health.expectedSchema}. Some results may not show. Update the app or '
            'the server to the same release.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Connect anyway'),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _connect() async {
    final invalid = ServerConfig.validateUrl(_url.text);
    if (invalid != null) {
      setState(() => _error = invalid);
      return;
    }
    final config = ServerConfig(
      baseUrl: ServerConfig.normalizeUrl(_url.text),
      token: _token.text.trim().isEmpty ? null : _token.text.trim(),
    );
    setState(() {
      _busy = true;
      _error = null;
    });
    // Read before the await: using ref after the screen is closed throws.
    final checkHealth = ref.read(healthCheckProvider);
    final configs = ref.read(serverConfigProvider.notifier);
    try {
      final health = await checkHealth(config);
      if (health.authRequired && config.token == null) {
        throw ApiException('This server needs an access token');
      }
      if (!health.schemaMatches && (!mounted || !await _confirmSchema(health))) return;
      await configs.save(config);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Connected: ShuttleSense ${health.version} on ${health.device.toUpperCase()}',
          ),
        ),
      );
      context.go(Routes.home);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showHelp() => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) => const SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Finding the server address', style: TextStyle(fontWeight: FontWeight.w600)),
            SizedBox(height: 8),
            Text(
              'Laptop on the same Wi-Fi: start the backend with '
              '"uvicorn shuttlesense.api.main:app --host 0.0.0.0 --port 8000", then use the '
              "laptop's IP address (Windows: ipconfig, IPv4 Address), e.g. "
              'http://192.168.1.20:8000.',
            ),
            SizedBox(height: 8),
            Text(
              'Google Colab: run the notebook; its last cell prints an https://….trycloudflare.com '
              'address and the access token you set.',
            ),
            SizedBox(height: 8),
            Text('More in docs/SETUP.md, section 8.'),
          ],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final recent = ref.read(serverConfigProvider.notifier).recent;
    final mixed =
        kIsWeb &&
        ServerConfig.isMixedContent(Uri.base.scheme, ServerConfig.normalizeUrl(_url.text));
    return PageScaffold(
      title: 'Connect to server',
      maxWidth: 480,
      actions: [
        IconButton(tooltip: 'Help', icon: const Icon(Icons.help_outline), onPressed: _showHelp),
      ],
      children: [
        Icon(Icons.sports_tennis, size: 56, color: theme.colorScheme.primary),
        const SizedBox(height: 12),
        Text('ShuttleSense', style: theme.textTheme.headlineSmall, textAlign: TextAlign.center),
        const SizedBox(height: 8),
        Text(
          'Enter the address of the ShuttleSense backend: the laptop on your Wi-Fi '
          '(for example http://192.168.1.20:8000) or the Colab tunnel URL.',
          style: theme.textTheme.bodyMedium,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        TextField(
          controller: _url,
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: 'Server address',
            hintText: 'http://192.168.1.20:8000',
            prefixIcon: Icon(Icons.dns_outlined),
          ),
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _connect(),
        ),
        if (recent.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final url in recent)
                ActionChip(
                  avatar: const Icon(Icons.history, size: 16),
                  label: Text(url),
                  onPressed: () => setState(() => _url.text = url),
                ),
            ],
          ),
        ],
        if (mixed) ...[
          const SizedBox(height: 8),
          Text(
            'This page is served over https, so the browser blocks plain http servers. '
            'Use the https tunnel address instead.',
            style: TextStyle(color: theme.colorScheme.error),
          ),
        ],
        const SizedBox(height: 12),
        TextField(
          controller: _token,
          obscureText: true,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: 'Access token (if the server has one)',
            prefixIcon: Icon(Icons.key_outlined),
          ),
          onSubmitted: (_) => _connect(),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(
            _error!,
            style: TextStyle(color: theme.colorScheme.error),
            semanticsLabel: 'Error: $_error',
          ),
        ],
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: _busy ? null : _connect,
          icon: _busy
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.link),
          label: const Text('Connect'),
        ),
      ],
    );
  }
}
