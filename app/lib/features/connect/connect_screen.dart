import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config/server_config.dart';
import '../../core/router/app_router.dart';
import '../../data/api_client.dart';
import '../../data/models/health.dart';
import '../../shared/widgets/surfaces.dart';
import '../../core/theme/tokens.dart';
import '../../ui/depth.dart';

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
      context.go(Routes.dashboard);
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
        padding: EdgeInsets.fromLTRB(Spacing.xl, 0, Spacing.xl, Spacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Finding the server address', style: TextStyle(fontWeight: FontWeight.w600)),
            SizedBox(height: Spacing.sm),
            Text(
              'Laptop on the same Wi-Fi: start the backend with '
              '"uvicorn shuttlesense.api.main:app --host 0.0.0.0 --port 8000", then use the '
              "laptop's IP address (Windows: ipconfig, IPv4 Address), e.g. "
              'http://192.168.1.20:8000.',
            ),
            SizedBox(height: Spacing.sm),
            Text(
              'Google Colab: run the notebook; its last cell prints an https://….trycloudflare.com '
              'address and the access token you set.',
            ),
            SizedBox(height: Spacing.sm),
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
    final p = AppPalette.of(context);
    final text = theme.textTheme;
    Widget note(String message, {required Color color, required IconData icon}) => Container(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.md, vertical: Spacing.sm + 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Text(
              message,
              style: text.bodySmall?.copyWith(color: color),
              semanticsLabel: 'Error: $message',
            ),
          ),
        ],
      ),
    );

    final card = AppCard(
      padding: const EdgeInsets.all(Spacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InsetBox(
            radius: Radii.md,
            child: TextField(
              controller: _url,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Server address',
                hintText: 'http://192.168.1.20:8000',
                prefixIcon: Icon(Icons.dns_outlined),
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _connect(),
            ),
          ),
          if (recent.isNotEmpty) ...[
            const SizedBox(height: Spacing.sm + 2),
            Wrap(
              spacing: Spacing.sm,
              runSpacing: Spacing.xs,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text('Recent', style: text.bodySmall?.copyWith(color: p.text3)),
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
            const SizedBox(height: Spacing.sm),
            note(
              'This page is served over https, so the browser blocks plain http servers. '
              'Use the https tunnel address instead.',
              color: theme.colorScheme.error,
              icon: Icons.lock_outline,
            ),
          ],
          const SizedBox(height: Spacing.lg),
          InsetBox(
            radius: Radii.md,
            child: TextField(
              controller: _token,
              obscureText: true,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Access token (if the server has one)',
                prefixIcon: Icon(Icons.key_outlined),
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
              ),
              onSubmitted: (_) => _connect(),
            ),
          ),
          if (_error case final error?) ...[
            const SizedBox(height: Spacing.md),
            note(error, color: theme.colorScheme.error, icon: Icons.error_outline),
          ],
          const SizedBox(height: Spacing.xl),
          SizedBox(
            height: 52,
            child: FilledButton.icon(
              onPressed: _busy ? null : _connect,
              icon: _busy
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.link),
              label: const Text('Connect'),
            ),
          ),
        ],
      ),
    );

    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            // One centred column: the brand, the card and where to find the address.
            Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: Spacing.lg, vertical: Spacing.xl),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 440),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Center(
                        child: IconWell(icon: Icons.sports_tennis, size: 64, iconSize: 30),
                      ),
                      const SizedBox(height: Spacing.lg),
                      Semantics(
                        header: true,
                        child: Text(
                          'Connect to server',
                          textAlign: TextAlign.center,
                          style: text.headlineMedium?.copyWith(fontWeight: FontWeight.w500),
                        ),
                      ),
                      const SizedBox(height: Spacing.xs),
                      Text(
                        'Link ShuttleSense to the computer that runs the analysis.',
                        textAlign: TextAlign.center,
                        style: text.bodyMedium?.copyWith(color: p.text2),
                      ),
                      const SizedBox(height: Spacing.xl),
                      card,
                      const SizedBox(height: Spacing.lg),
                      // Where the address comes from, in two short lines.
                      for (final (icon, where, what) in const [
                        (Icons.wifi, 'Same Wi-Fi', "the laptop's address, port 8000"),
                        (Icons.cloud_outlined, 'Colab', 'the https tunnel address it prints'),
                      ])
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: Row(
                            children: [
                              Icon(icon, size: 16, color: p.text3),
                              const SizedBox(width: Spacing.sm),
                              Flexible(
                                child: Text.rich(
                                  TextSpan(
                                    children: [
                                      TextSpan(
                                        text: '$where: ',
                                        style: TextStyle(
                                          color: p.text2,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      TextSpan(text: what),
                                    ],
                                  ),
                                  style: text.bodySmall?.copyWith(color: p.text3),
                                ),
                              ),
                            ],
                          ),
                        ),
                      const SizedBox(height: Spacing.sm),
                      Center(
                        child: TextButton.icon(
                          onPressed: _showHelp,
                          icon: const Icon(Icons.help_outline, size: 18),
                          label: const Text('How to find the address'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
