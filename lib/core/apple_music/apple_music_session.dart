import 'dart:async' show unawaited;

import 'package:lauschi/core/apple_music/apple_music_api.dart';
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

/// Central provider for Apple Music auth, native playback, and API.
///
/// Auth goes through the web flow: system browser → MusicKit JS authorize()
/// → server-side 302 redirect → deep link back to the app. Same pattern
/// as Spotify.
///
/// Playback uses Apple's native Android SDK (MediaPlayerController) instead
/// of MusicKit JS in a WebView. The web-obtained Music User Token is passed
/// to the native SDK via setMusicUserToken(). This avoids WebView DRM
/// limitations (Widevine L3 only on many Android devices).
@Riverpod(keepAlive: true)
class AppleMusicSession extends _$AppleMusicSession {
  // Native MusicKit SDK: developer token generation (JWT from .p8 key)
  // and native playback via MediaPlayerController.
  final MusicKit _musicKit = MusicKit();

  final AppleMusicApi _api = AppleMusicApi();
  final AppleMusicWebAuth _webAuth = AppleMusicWebAuth();

  bool _playerInitialized = false;

  @override
  AppleMusicState build() {
    unawaited(_init());
    return AppleMusicLoading();
  }

  // ── Public accessors ────────────────────────────────────────────────

  MusicKit get musicKit => _musicKit;
  AppleMusicApi get api => _api;
  AppleMusicWebAuth get webAuth => _webAuth;
  bool get isAuthenticated => state is AppleMusicAuthenticated;

  // ── Init ────────────────────────────────────────────────────────────

  Future<void> _init() async {
    try {
      final webTokens = await _webAuth.loadStored();
      if (webTokens != null) {
        final devToken = await _musicKit.requestDeveloperToken();
        _configureApi(devToken, webTokens.storefront);
        await _initNativePlayer(webTokens.musicUserToken);
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
    } on Exception catch (e) {
      Log.error(_tag, 'Init failed', exception: e);
      state = AppleMusicUnauthenticated();
    }
  }

  // ── Auth flow ───────────────────────────────────────────────────────

  /// Start the Apple Music web auth flow.
  Future<void> connect() async {
    state = AppleMusicLoading();
    try {
      final devToken = await _musicKit.requestDeveloperToken();
      final tokens = await _webAuth.login(developerToken: devToken);

      _configureApi(devToken, tokens.storefront);
      await _initNativePlayer(tokens.musicUserToken);
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
        _configureApi(devToken, tokens.storefront);
        await _initNativePlayer(tokens.musicUserToken);
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

  /// Disconnect. Stops playback, clears web token.
  Future<void> disconnect() async {
    if (_playerInitialized) {
      try {
        await _musicKit.stop();
      } on Exception catch (_) {
        // Player might not be active.
      }
      _playerInitialized = false;
    }
    await _webAuth.logout();
    state = AppleMusicUnauthenticated();
    Log.info(_tag, 'Disconnected');
  }

  // ── Native player ──────────────────────────────────────────────────

  /// Pass the web MUT to the native MediaPlayerController.
  Future<void> _initNativePlayer(String musicUserToken) async {
    if (_playerInitialized) return;
    try {
      await _musicKit.setMusicUserToken(musicUserToken);
      _playerInitialized = true;
      Log.info(_tag, 'Native player initialized');
    } on Exception catch (e) {
      Log.error(_tag, 'Native player init failed', exception: e);
    }
  }

  // ── Internal ────────────────────────────────────────────────────────

  void _configureApi(String devToken, String storefront) {
    _api.configure(developerToken: devToken, storefront: storefront);
  }
}
