import 'dart:async' show StreamSubscription, unawaited;

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lauschi/core/database/data_migrations.dart';
import 'package:lauschi/core/database/tile_item_repository.dart';
import 'package:lauschi/core/feature_flags.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/nfc/nfc_listener.dart';
import 'package:lauschi/core/router/app_router.dart';
import 'package:lauschi/core/spotify/spotify_auth_provider.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/onboarding/screens/onboarding_provider.dart';
import 'package:lauschi/features/player/player_provider.dart';
import 'package:lauschi/features/player/spotify_player_bridge.dart';
import 'package:webview_flutter/webview_flutter.dart';

class LauschiApp extends ConsumerStatefulWidget {
  const LauschiApp({super.key});

  @override
  ConsumerState<LauschiApp> createState() => _LauschiAppState();
}

class _LauschiAppState extends ConsumerState<LauschiApp>
    with WidgetsBindingObserver {
  late final AppLinks _appLinks;
  StreamSubscription<Uri>? _linkSub;

  bool _dataMigrationsRun = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(
      ref.read(onboardingCompleteProvider.notifier).checkAsync(),
    );
    unawaited(_initDeepLinks());
  }

  Future<void> _initDeepLinks() async {
    _appLinks = AppLinks();

    // Handle link that launched the app (cold start)
    final initial = await _appLinks.getInitialLink();
    if (initial != null) await _handleDeepLink(initial);

    // Handle links while app is running (warm start)
    _linkSub = _appLinks.uriLinkStream.listen(_onDeepLink);
  }

  void _onDeepLink(Uri uri) {
    unawaited(_handleDeepLink(uri));
  }

  Future<void> _handleDeepLink(Uri uri) async {
    Log.info('DeepLink', 'Received', data: {'uri': '$uri'});
    if (FeatureFlags.enableSpotify &&
        uri.scheme == 'lauschi' &&
        uri.host == 'callback') {
      try {
        final auth = ref.read(spotifyAuthClientProvider);
        final tokens = await auth.handleCallback(uri);
        // If tokens were recovered from storage (app was killed during OAuth),
        // update the auth state directly since no login() future is waiting.
        if (tokens != null) {
          ref.read(spotifyAuthProvider.notifier).authenticateWith(tokens);
        }
      } on Exception catch (e, stack) {
        Log.error(
          'DeepLink',
          'OAuth callback failed',
          exception: e,
          stackTrace: stack,
        );
      }
    }
  }

  // No didChangeAppLifecycleState — audio_service + MediaSessionHandler
  // handle background playback. Pausing on inactive/paused killed audio on
  // screen lock, notification pulldown, and rotation. See #103.

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_linkSub?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(appRouterProvider);

    // Activate NFC listener (no-op if disabled in settings or no hardware).
    ref.watch(nfcListenerProvider);

    // Spotify-only: watch auth for WebView + data migrations.
    final spotifyAuth =
        FeatureFlags.enableSpotify ? ref.watch(spotifyAuthProvider) : null;

    // Run data migrations once after Spotify auth is established.
    if (spotifyAuth is AuthAuthenticated && !_dataMigrationsRun) {
      _dataMigrationsRun = true;
      unawaited(
        runDataMigrations(
          DataMigrationContext(
            cards: ref.read(tileItemRepositoryProvider),
            api: ref.read(spotifyApiProvider),
          ),
        ),
      );
    }

    return MaterialApp.router(
      title: 'lauschi',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      routerConfig: router,
      builder: (context, child) {
        return Stack(
          children: [
            child ?? const SizedBox.shrink(),
            // Hidden WebView for Spotify Web Playback SDK.
            // Needs real dimensions (300x300) — WebView suspends media
            // in undersized containers.
            if (FeatureFlags.enableSpotify && spotifyAuth is AuthAuthenticated)
              Positioned(
                left: -500,
                top: -500,
                child: SizedBox(
                  width: 300,
                  height: 300,
                  child: _WebViewHost(),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Hosts the hidden WebView for Spotify Web Playback SDK.
///
/// Must have real dimensions (300x300). Placed off-screen.
class _WebViewHost extends ConsumerStatefulWidget {
  @override
  ConsumerState<_WebViewHost> createState() => _WebViewHostState();
}

class _WebViewHostState extends ConsumerState<_WebViewHost> {
  bool _initialized = false;

  /// Stored in initState for use in dispose() where ref is no longer safe.
  late final SpotifyPlayerBridge _bridge;

  @override
  void initState() {
    super.initState();
    _bridge = ref.read(spotifyPlayerBridgeProvider);
    unawaited(_initBridge());
  }

  Future<void> _initBridge() async {
    if (_initialized) return;
    _initialized = true;
    await ref.read(playerProvider.notifier).initBridge();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    // Disconnect the bridge when the WebView is removed (e.g. logout).
    // The bridge is keepAlive, so ref.onDispose won't fire — we need to
    // disconnect explicitly here. See #214.
    // Uses _bridge (cached in field) instead of ref.read() because ref
    // is unsafe during dispose. See LAUSCHI-Y.
    unawaited(_bridge.reconnect().catchError((_) {}));
    final controller = _bridge.controllerOrNull;
    if (controller != null) {
      unawaited(controller.loadRequest(Uri.parse('about:blank')));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bridge = ref.watch(spotifyPlayerBridgeProvider);
    if (!bridge.currentState.isReady && !_initialized) {
      return const SizedBox.shrink();
    }
    // The controller may not be available yet during init.
    final controller = bridge.controllerOrNull;
    if (controller == null) return const SizedBox.shrink();
    return WebViewWidget(controller: controller);
  }
}
