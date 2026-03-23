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
      state = AppleMusicUnauthenticated();
      Log.info(_tag, 'Stored token expired, needs re-auth');
    } on Exception catch (e) {
      Log.error(_tag, 'Init failed', exception: e);
      state = AppleMusicUnauthenticated();
    }
  }

  Future<void> _initIos() async {
    // On iOS, check native MusicKit authorization (device-level).
    final authStatus = await _musicKit.nativeAuthStatus;
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
        final authStatus = await _musicKit.requestNativeAuth();
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
      Log.warn(_tag, 'Auth failed', data: {'error': '$e'});
      state = AppleMusicUnauthenticated();
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
      state = AppleMusicUnauthenticated();
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
