import 'dart:async' show unawaited;
import 'dart:io' show Platform;

import 'package:lauschi/core/apple_music/apple_music_api.dart';
import 'package:lauschi/core/apple_music/apple_music_stream_resolver.dart';
import 'package:lauschi/core/apple_music/apple_music_web_auth.dart';
import 'package:lauschi/core/log.dart';
import 'package:music_kit/music_kit.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'apple_music_session.g.dart';

const _tag = 'AppleMusicSession';

// ---------------------------------------------------------------------------
// Session state
// ---------------------------------------------------------------------------

/// Apple Music session state. Drives UI (what to show) and player
/// init (whether the Apple Music backend can play content).
///
/// State semantics mirror `SpotifySessionState`:
/// - [AppleMusicLoading]: in-progress (token check, refresh, web auth)
/// - [AppleMusicAuthenticated]: ready to use
/// - [AppleMusicUnauthenticated]: terminal "no credentials, user must
///   re-authenticate". Reached on cold start with no stored token,
///   on token expiry, on user-denied native auth, on logout.
/// - [AppleMusicError]: terminal "something went wrong that isn't the
///   user's fault". Reached when MusicKit JWT generation throws, when
///   the web auth flow returns an unexpected exception, when token
///   decryption fails, etc. UI should treat this like Unauthenticated
///   for the connect prompt, but the message field gives diagnostics.
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

class AppleMusicError extends AppleMusicState {
  AppleMusicError(this.message);
  final String message;
}

// ---------------------------------------------------------------------------
// AppleMusicSession provider
// ---------------------------------------------------------------------------

/// Central provider for Apple Music auth, streaming, and API.
///
/// Auth strategy differs by platform:
/// - **iOS:** Native MusicKit authorization (system popup). Uses the
///   device-level Apple Music subscription. No tokens to manage.
/// - **Android:** Web OAuth via MusicKit JS. Tokens stored in
///   FlutterSecureStorage, injected into the DRM player.
@Riverpod(keepAlive: true)
class AppleMusicSession extends _$AppleMusicSession {
  // Native MusicKit SDK: only for developer token generation (JWT from .p8 key).
  final MusicKit _musicKit = MusicKit();

  final AppleMusicApi _api = AppleMusicApi();
  final AppleMusicStreamResolver _streamResolver = AppleMusicStreamResolver();
  final AppleMusicWebAuth _webAuth = AppleMusicWebAuth();

  @override
  AppleMusicState build() {
    unawaited(_init());
    return AppleMusicLoading();
  }

  // ── Public accessors ────────────────────────────────────────────────

  MusicKit get musicKit => _musicKit;
  AppleMusicApi get api => _api;
  AppleMusicStreamResolver get streamResolver => _streamResolver;
  AppleMusicWebAuth get webAuth => _webAuth;
  bool get isAuthenticated => state is AppleMusicAuthenticated;

  // ── Init ────────────────────────────────────────────────────────────

  Future<void> _init() async {
    try {
      if (Platform.isIOS) {
        await _initIos();
      } else {
        await _initAndroid();
      }
    } on AppleMusicAuthExpiredException {
      // Token expiry is a normal lifecycle event: the user needs to
      // re-authenticate. Not an error.
      state = AppleMusicUnauthenticated();
      Log.info(_tag, 'Stored token expired, needs re-auth');
    } on Exception catch (e) {
      // Anything else (JWT generation failure, native plugin throw,
      // platform channel error) is a real error. Surface the message
      // so callers can show useful diagnostics instead of silently
      // looking like "no credentials".
      Log.error(_tag, 'Init failed', exception: e);
      state = AppleMusicError('Init failed: $e');
    }
  }

  Future<void> _initIos() async {
    // On iOS, check native MusicKit authorization (device-level).
    final authStatus = await _musicKit.authorizationStatus;
    if (authStatus is MusicAuthorizationStatusAuthorized) {
      // MusicKit generates the developer token internally on iOS.
      // We still need it for the catalog API (REST calls).
      final devToken = await _musicKit.requestDeveloperToken();
      final storefront = await _musicKit.currentCountryCode;
      _api.configure(developerToken: devToken, storefront: storefront);
      state = AppleMusicAuthenticated(
        developerToken: devToken,
        musicUserToken:
            '', // Not used on iOS; MusicKit handles auth internally.
        storefront: storefront,
      );
      Log.info(
        _tag,
        'iOS: MusicKit authorized',
        data: {'storefront': storefront},
      );
    } else {
      state = AppleMusicUnauthenticated();
      Log.info(_tag, 'iOS: MusicKit not authorized');
    }
  }

  Future<void> _initAndroid() async {
    final webTokens = await _webAuth.loadStored();
    if (webTokens != null) {
      final devToken = await _musicKit.requestDeveloperToken();
      _configure(devToken, webTokens.musicUserToken, webTokens.storefront);
      // Pass token to native side to trigger TLS pre-warming.
      unawaited(_musicKit.setMusicUserToken(webTokens.musicUserToken));
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

    state = AppleMusicUnauthenticated();
    Log.info(_tag, 'No stored token, needs web auth');
  }

  // ── Auth flow ───────────────────────────────────────────────────────

  Future<void> connect() async {
    state = AppleMusicLoading();
    try {
      if (Platform.isIOS) {
        // Native MusicKit auth: system popup.
        final authStatus = await _musicKit.requestAuthorizationStatus();
        if (authStatus is MusicAuthorizationStatusAuthorized) {
          final devToken = await _musicKit.requestDeveloperToken();
          final storefront = await _musicKit.currentCountryCode.catchError(
            (_) => 'de',
          );
          _api.configure(developerToken: devToken, storefront: storefront);
          state = AppleMusicAuthenticated(
            developerToken: devToken,
            musicUserToken: '',
            storefront: storefront,
          );
          Log.info(_tag, 'Connected via native MusicKit auth');
        } else {
          // User denied the system popup. Not an error — the user
          // chose this. Stay Unauthenticated and let them retry later.
          state = AppleMusicUnauthenticated();
          Log.warn(_tag, 'Native auth denied');
        }
      } else {
        // Android: web auth flow.
        final devToken = await _musicKit.requestDeveloperToken();
        final tokens = await _webAuth.login(developerToken: devToken);
        _configure(devToken, tokens.musicUserToken, tokens.storefront);
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
      }
    } on Exception catch (e) {
      // The auth flow itself threw — e.g., the web auth WebView
      // crashed, the JWT signing failed, the network dropped during
      // the OAuth round-trip. This is an error, not "user has no
      // credentials" (Spotify uses the same distinction).
      Log.error(_tag, 'Auth failed', exception: e);
      state = AppleMusicError('Connect failed: $e');
    }
  }

  Future<bool> handleCallback(Uri uri) async {
    try {
      final tokens = await _webAuth.handleCallback(uri);
      if (tokens != null) {
        final devToken = await _musicKit.requestDeveloperToken();
        _configure(devToken, tokens.musicUserToken, tokens.storefront);
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
      state = AppleMusicError('OAuth callback failed: $e');
      return false;
    }
  }

  Future<void> disconnect() async {
    if (!Platform.isIOS) {
      await _webAuth.logout();
    }
    // On iOS, native MusicKit auth can't be revoked from within the app.
    // The user manages this in Settings → Privacy → Media & Apple Music.
    state = AppleMusicUnauthenticated();
    Log.info(_tag, 'Disconnected');
  }

  // ── Internal ────────────────────────────────────────────────────────

  void _configure(String devToken, String musicUserToken, String storefront) {
    _api.configure(developerToken: devToken, storefront: storefront);
    _streamResolver.configure(
      developerToken: devToken,
      musicUserToken: musicUserToken,
    );
  }

  /// Re-warm TLS connections to Apple's servers. Called on app resume
  /// from background (screen on after idle, app foregrounded after switch).
  /// Connections may have been evicted during idle/Doze.
  void prewarmConnections() {
    // TLS pre-warm is Android-only (Fairphone 6 TLS handshake issue).
    // iOS uses Network.framework which handles TLS session resumption
    // automatically. With native MusicKit, no direct HTTP calls are made.
    if (Platform.isIOS) return;
    if (state is! AppleMusicAuthenticated) return;
    final auth = state as AppleMusicAuthenticated;
    unawaited(_musicKit.setMusicUserToken(auth.musicUserToken));
  }
}
