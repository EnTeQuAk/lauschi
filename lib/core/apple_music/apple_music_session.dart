import 'dart:async' show unawaited;

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
/// Auth goes through the web flow: system browser → MusicKit JS authorize()
/// → server-side 302 redirect → deep link back to the app.
///
/// Playback uses Apple's webPlayback API to get HLS stream URLs, played
/// via just_audio (ExoPlayer). No WebView, no native MediaPlayerController.
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

  AppleMusicApi get api => _api;
  AppleMusicStreamResolver get streamResolver => _streamResolver;
  AppleMusicWebAuth get webAuth => _webAuth;
  bool get isAuthenticated => state is AppleMusicAuthenticated;

  // ── Init ────────────────────────────────────────────────────────────

  Future<void> _init() async {
    try {
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
    } on AppleMusicAuthExpiredException {
      state = AppleMusicUnauthenticated();
      Log.info(_tag, 'Stored token expired, needs re-auth');
    } on Exception catch (e) {
      Log.error(_tag, 'Init failed', exception: e);
      state = AppleMusicUnauthenticated();
    }
  }

  // ── Auth flow ───────────────────────────────────────────────────────

  Future<void> connect() async {
    state = AppleMusicLoading();
    try {
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
    } on Exception catch (e) {
      Log.warn(_tag, 'Web auth failed', data: {'error': '$e'});
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
    await _webAuth.logout();
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
}
