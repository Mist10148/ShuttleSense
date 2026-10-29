import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config/server_config.dart';
import '../../core/router/app_router.dart';
import '../../data/api_client.dart';
import '../../shared/widgets/page_scaffold.dart';

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

  Future<void> _connect() async {
    final config = ServerConfig(
      baseUrl: ServerConfig.normalizeUrl(_url.text),
      token: _token.text.trim().isEmpty ? null : _token.text.trim(),
    );
    if (config.baseUrl.isEmpty) {
      setState(() => _error = 'Enter the server address');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final health = await ApiClient(config).health();
      if (health.authRequired && config.token == null) {
        throw ApiException('This server needs an access token');
      }
      await ref.read(serverConfigProvider.notifier).save(config);
      if (mounted) context.go(Routes.home);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PageScaffold(
      title: 'Connect to server',
      maxWidth: 480,
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
          onSubmitted: (_) => _connect(),
        ),
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
          Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
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
