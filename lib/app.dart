import 'dart:async' show StreamSubscription, unawaited;

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lauschi/core/database/card_repository.dart';
import 'package:lauschi/core/database/data_migrations.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/nfc/nfc_listener.dart';
import 'package:lauschi/core/router/app_router.dart';
import 'package:lauschi/core/spotify/spotify_auth_provider.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/onboarding/screens/onboarding_provider.dart';
import 'package:lauschi/features/player/player_provider.dart';
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

  /// Whether playback was active when the app went to background.
  /// Used to auto-resume on foreground.
  bool _wasPlayingBeforePause = false;

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
    if (uri.scheme == 'lauschi' && uri.host == 'callback') {
      final auth = ref.read(spotifyAuthClientProvider);
      final tokens = await auth.handleCallback(uri);
      // If tokens were recovered from storage (app was killed during OAuth),
      // update the auth state directly since no login() future is waiting.
      if (tokens != null) {
        ref.read(spotifyAuthProvider.notifier).authenticateWith(tokens);
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final player = ref.read(playerProvider.notifier);
    final playback = ref.read(playerProvider);

    switch (state) {
      case AppLifecycleState.paused || AppLifecycleState.inactive:
        // App going to background — pause if playing, remember state.
        if (playback.isPlaying) {
          _wasPlayingBeforePause = true;
          Log.info('Lifecycle', 'Pausing playback (app backgrounded)');
          unawaited(player.pause());
        }
      case AppLifecycleState.resumed:
        // App returning to foreground — resume if we paused it.
        if (_wasPlayingBeforePause) {
          _wasPlayingBeforePause = false;
          Log.info('Lifecycle', 'Resuming playback (app foregrounded)');
          unawaited(player.resume());
        }
      case AppLifecycleState.detached || AppLifecycleState.hidden:
        break;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_linkSub?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(appRouterProvider);
    final authState = ref.watch(spotifyAuthProvider);

    // Activate NFC listener (no-op if disabled in settings or no hardware).
    ref.watch(nfcListenerProvider);

    // Run data migrations once after auth is established.
    if (authState is AuthAuthenticated && !_dataMigrationsRun) {
      _dataMigrationsRun = true;
      unawaited(
        runDataMigrations(
          DataMigrationContext(
            cards: ref.read(cardRepositoryProvider),
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
            if (authState is AuthAuthenticated)
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

  @override
  void initState() {
    super.initState();
    unawaited(_initBridge());
  }

  Future<void> _initBridge() async {
    if (_initialized) return;
    _initialized = true;
    await ref.read(playerProvider.notifier).initBridge();
    if (mounted) setState(() {});
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
