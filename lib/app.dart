import 'dart:async' show StreamSubscription, unawaited;

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lauschi/core/apple_music/apple_music_session.dart';
import 'package:lauschi/core/database/data_migrations.dart';
import 'package:lauschi/core/database/tile_item_repository.dart';
import 'package:lauschi/core/feature_flags.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/nfc/nfc_listener.dart';
import 'package:lauschi/core/router/app_router.dart';
import 'package:lauschi/core/spotify/spotify_session.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/onboarding/screens/onboarding_provider.dart';
import 'package:webview_flutter/webview_flutter.dart'; // Used by _SpotifyWebViewHost

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
    if (uri.scheme != 'lauschi') return;

    if (FeatureFlags.enableSpotify && uri.host == 'callback') {
      try {
        await ref.read(spotifySessionProvider.notifier).handleCallback(uri);
      } on Exception catch (e, stack) {
        Log.error(
          'DeepLink',
          'Spotify callback failed',
          exception: e,
          stackTrace: stack,
        );
      }
    }

    if (FeatureFlags.enableAppleMusic && uri.host == 'apple-music-callback') {
      try {
        await ref.read(appleMusicSessionProvider.notifier).handleCallback(uri);
      } on Exception catch (e, stack) {
        Log.error(
          'DeepLink',
          'Apple Music callback failed',
          exception: e,
          stackTrace: stack,
        );
      }
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

    // Activate NFC listener (no-op if disabled in settings or no hardware).
    ref.watch(nfcListenerProvider);

    // Watch provider session states for WebView mounting.
    final spotifyState =
        FeatureFlags.enableSpotify ? ref.watch(spotifySessionProvider) : null;
    final spotifyAuthenticated = spotifyState is SpotifyAuthenticated;

    // Apple Music uses native playback (MediaPlayerController), no WebView needed.
    // Just watch the state for conditional UI, not for WebView mounting.
    if (FeatureFlags.enableAppleMusic) {
      ref.watch(appleMusicSessionProvider);
    }

    // Run data migrations once after Spotify auth is established.
    if (spotifyAuthenticated && !_dataMigrationsRun) {
      _dataMigrationsRun = true;
      final session = ref.read(spotifySessionProvider.notifier);
      unawaited(
        runDataMigrations(
          DataMigrationContext(
            cards: ref.read(tileItemRepositoryProvider),
            api: session.api,
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
            if (FeatureFlags.enableSpotify && spotifyAuthenticated)
              Positioned(
                left: -500,
                top: -500,
                child: SizedBox(
                  width: 300,
                  height: 300,
                  child: _SpotifyWebViewHost(),
                ),
              ),
            // Apple Music uses native playback, no hidden WebView needed.
          ],
        );
      },
    );
  }
}

/// Hosts the hidden WebView for Spotify Web Playback SDK.
///
/// Pure view layer: mounts/unmounts based on auth state (driven by
/// app.dart's conditional rendering). Bridge lifecycle (init, tearDown)
/// is managed by [SpotifySession], not by this widget.
///
/// Must have real dimensions (300x300). Placed off-screen.
class _SpotifyWebViewHost extends ConsumerStatefulWidget {
  @override
  ConsumerState<_SpotifyWebViewHost> createState() =>
      _SpotifyWebViewHostState();
}

class _SpotifyWebViewHostState extends ConsumerState<_SpotifyWebViewHost> {
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    unawaited(_initBridge());
  }

  Future<void> _initBridge() async {
    if (_initialized) return;
    try {
      await ref.read(spotifySessionProvider.notifier).initBridge();
      _initialized = true;
      if (mounted) setState(() {});
    } on Exception catch (e) {
      // Don't set _initialized — allows retry on next mount.
      Log.error('WebViewHost', 'Bridge init failed', exception: e);
    }
  }

  @override
  void dispose() {
    // No bridge lifecycle management here. SpotifySession.logout()
    // handles tearDown before the widget unmounts.
    // See Sentry LAUSCHI-Z (StateError during token callback after logout).
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // ref.read, not ref.watch: this widget is conditionally rendered
    // by the parent based on auth state. We just need the bridge
    // reference to get the WebView controller.
    final session = ref.read(spotifySessionProvider.notifier);
    final bridge = session.bridge;
    if (!bridge.currentState.isReady && !_initialized) {
      return const SizedBox.shrink();
    }
    final controller = bridge.controllerOrNull;
    if (controller == null) return const SizedBox.shrink();
    return WebViewWidget(controller: controller);
  }
}

// Apple Music uses native playback via MediaPlayerController.
// No WebView host widget needed (unlike Spotify which uses Web Playback SDK).
