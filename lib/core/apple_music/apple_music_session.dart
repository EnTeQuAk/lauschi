import 'dart:async' show unawaited;

import 'package:lauschi/core/apple_music/apple_music_api.dart';
import 'package:lauschi/core/apple_music/apple_music_web_auth.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/features/player/apple_music_webview_bridge.dart';
import 'package:music_kit/music_kit.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'apple_music_session.g.dart';

const _tag = 'AppleMusicSession';

// ---------------------------------------------------------------------------
// Session state
// ---------------------------------------------------------------------------

sealed class AppleMusicState {}

class AppleMusicLoading extends AppleMusicState {}

class AppleMusicUnauthenticated extends AppleMusicState {}

class AppleMusicAuthenticated extends AppleMusicState {
  AppleMusicAuthenticated({
    required this.developerToken,
    required this.musicUserToken,
    required this.storefront,
  });

  final String developerToken;
  final String musicUserToken;
  final String storefront;
}

// ---------------------------------------------------------------------------
// AppleMusicSession provider
// ---------------------------------------------------------------------------

/// Central provider for Apple Music auth, playback bridge, and API.
///
/// Auth uses two paths:
/// - **Native MusicKit SDK**: for catalog API calls (developer token + native auth)
/// - **Web auth via system browser**: for playback token (same pattern as Spotify)
///
/// The web auth flow opens the system browser with an auth page that runs
/// MusicKit JS authorize(). After login, it redirects back to the app with
/// the music user token. This token is then passed to the WebView bridge
/// for playback via MusicKit JS.
@Riverpod(keepAlive: true)
class AppleMusicSession extends _$AppleMusicSession {
  final MusicKit _musicKit = MusicKit();
  late final AppleMusicApi _api = AppleMusicApi(_musicKit);
  final AppleMusicWebViewBridge _bridge = AppleMusicWebViewBridge();
  final AppleMusicWebAuth _webAuth = AppleMusicWebAuth();

  bool _bridgeInitialized = false;

  @override
  AppleMusicState build() {
    ref.onDispose(_tearDownBridge);
    unawaited(_init());
    return AppleMusicLoading();
  }

  // ── Public accessors ────────────────────────────────────────────────

  MusicKit get musicKit => _musicKit;
  AppleMusicApi get api => _api;
  AppleMusicWebViewBridge get bridge => _bridge;
  AppleMusicWebAuth get webAuth => _webAuth;
  bool get isAuthenticated => state is AppleMusicAuthenticated;

  // ── Init ────────────────────────────────────────────────────────────

  Future<void> _init() async {
    try {
      // Try to load stored web auth token first (persisted from previous
      // browser auth flow, like Spotify's stored tokens).
      final webTokens = await _webAuth.loadStored();
      if (webTokens != null) {
        final devToken = await _musicKit.requestDeveloperToken();
        state = AppleMusicAuthenticated(
          developerToken: devToken,
          musicUserToken: webTokens.musicUserToken,
          storefront: webTokens.storefront,
        );
        Log.info(
          _tag,
          'Restored from stored web token',
          data: {'storefront': webTokens.storefront},
        );
        return;
      }

      // No web token stored. Check native auth status (for catalog API).
      // User needs to connect via web auth for playback.
      final status = await _musicKit.authorizationStatus;
      Log.info(
        _tag,
        'Auth check on init',
        data: {'status': status.runtimeType.toString()},
      );

      // Even with native auth, we need web auth for playback.
      // Show as unauthenticated so the user goes through web auth.
      state = AppleMusicUnauthenticated();
    } on Exception catch (e) {
      Log.error(_tag, 'Init failed', exception: e);
      state = AppleMusicUnauthenticated();
    }
  }

  // ── Auth flow ───────────────────────────────────────────────────────

  /// Start the Apple Music web auth flow.
  ///
  /// Opens the system browser with the auth page. MusicKit JS handles
  /// the Apple login popup. After login, the browser redirects back
  /// to the app with the music user token.
  Future<void> connect() async {
    state = AppleMusicLoading();
    try {
      final devToken = await _musicKit.requestDeveloperToken();
      final tokens = await _webAuth.login(developerToken: devToken);

      state = AppleMusicAuthenticated(
        developerToken: devToken,
        musicUserToken: tokens.musicUserToken,
        storefront: tokens.storefront,
      );
      Log.info(
        _tag,
        'Connected via web auth',
        data: {'storefront': tokens.storefront},
      );
    } on Exception catch (e) {
      Log.warn(_tag, 'Web auth failed', data: {'error': '$e'});
      state = AppleMusicUnauthenticated();
    }
  }

  /// Handle the deep link callback from the auth page.
  Future<bool> handleCallback(Uri uri) async {
    try {
      final tokens = await _webAuth.handleCallback(uri);
      if (tokens != null) {
        final devToken = await _musicKit.requestDeveloperToken();
        state = AppleMusicAuthenticated(
          developerToken: devToken,
          musicUserToken: tokens.musicUserToken,
          storefront: tokens.storefront,
        );
        Log.info(_tag, 'Authenticated via callback');
        return true;
      }
      return false;
    } on Exception catch (e, stack) {
      Log.error(_tag, 'Callback failed', exception: e, stackTrace: stack);
      state = AppleMusicUnauthenticated();
      return false;
    }
  }

  /// Disconnect. Tears down bridge, clears web token.
  Future<void> disconnect() async {
    _tearDownBridge();
    await _webAuth.logout();
    state = AppleMusicUnauthenticated();
    Log.info(_tag, 'Disconnected');
  }

  // ── Bridge lifecycle ────────────────────────────────────────────────

  Future<void> initBridge() async {
    if (!isAuthenticated) {
      Log.warn(_tag, 'Cannot init bridge: not authenticated');
      return;
    }
    if (_bridgeInitialized) {
      Log.debug(_tag, 'Bridge already initialized');
      return;
    }

    final auth = state as AppleMusicAuthenticated;
    await _bridge.init(
      developerToken: auth.developerToken,
      musicUserToken: auth.musicUserToken,
    );
    _bridgeInitialized = true;
    Log.info(_tag, 'Bridge initialized');
  }

  void _tearDownBridge() {
    if (!_bridgeInitialized) return;
    _bridge.tearDown();
    _bridgeInitialized = false;
    Log.info(_tag, 'Bridge torn down');
  }
}
