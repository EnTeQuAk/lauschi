import 'dart:async' show unawaited;

import 'package:lauschi/core/apple_music/apple_music_api.dart';
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
  });

  final String developerToken;
  final String musicUserToken;
}

// ---------------------------------------------------------------------------
// AppleMusicSession provider
// ---------------------------------------------------------------------------

/// Central provider for Apple Music auth, playback bridge, and API.
///
/// Auth uses the native MusicKit plugin (handles credentials, popup, token
/// persistence). Playback uses MusicKit JS in a WebView (via the bridge).
/// The native SDK is only used for auth and catalog API calls; all audio
/// goes through the WebView to avoid the ~30-60s native SDK startup latency.
@Riverpod(keepAlive: true)
class AppleMusicSession extends _$AppleMusicSession {
  final MusicKit _musicKit = MusicKit();
  late final AppleMusicApi _api = AppleMusicApi(_musicKit);
  final AppleMusicWebViewBridge _bridge = AppleMusicWebViewBridge();

  /// Whether the bridge has been initialized in this auth session.
  bool _bridgeInitialized = false;

  @override
  AppleMusicState build() {
    ref.onDispose(_tearDownBridge);
    unawaited(_init());
    return AppleMusicLoading();
  }

  // ── Public accessors ────────────────────────────────────────────────

  MusicKit get musicKit => _musicKit;

  /// REST API client for catalog browsing.
  AppleMusicApi get api => _api;

  /// WebView bridge for MusicKit JS playback.
  AppleMusicWebViewBridge get bridge => _bridge;

  bool get isAuthenticated => state is AppleMusicAuthenticated;

  // ── Init ────────────────────────────────────────────────────────────

  Future<void> _init() async {
    try {
      final status = await _musicKit.authorizationStatus;
      Log.info(
        _tag,
        'Auth check on init',
        data: {'status': status.runtimeType.toString()},
      );
      if (status is MusicAuthorizationStatusAuthorized &&
          status.musicUserToken != null) {
        await _setAuthenticated(status.musicUserToken!);
      } else {
        state = AppleMusicUnauthenticated();
      }
    } on Exception catch (e) {
      Log.error(_tag, 'Init failed', exception: e);
      state = AppleMusicUnauthenticated();
    }
  }

  // ── Auth flow ───────────────────────────────────────────────────────

  /// Prompt the user to authorize Apple Music access.
  Future<void> connect() async {
    state = AppleMusicLoading();
    try {
      final result = await _musicKit.requestAuthorizationStatus(
        startScreenMessage:
            'lauschi braucht Zugriff auf Apple Music, um '
            'Hörspiele abspielen zu können.',
      );

      if (result is MusicAuthorizationStatusAuthorized &&
          result.musicUserToken != null) {
        await _setAuthenticated(result.musicUserToken!);
        Log.info(_tag, 'Connected');
      } else {
        state = AppleMusicUnauthenticated();
        Log.info(
          _tag,
          'Auth declined',
          data: {'status': result.runtimeType.toString()},
        );
      }
    } on Exception catch (e) {
      Log.warn(_tag, 'Auth flow error', data: {'error': '$e'});
      state = AppleMusicUnauthenticated();
    }
  }

  /// Disconnect. Tears down bridge, clears Dart state.
  Future<void> disconnect() async {
    _tearDownBridge();
    state = AppleMusicUnauthenticated();
    Log.info(_tag, 'Disconnected');
  }

  // ── Bridge lifecycle ────────────────────────────────────────────────

  /// Initialize the WebView bridge with current tokens.
  ///
  /// Called after the WebView widget mounts (needs a live WebView).
  /// Must be authenticated first.
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

  // ── Internal ────────────────────────────────────────────────────────

  Future<void> _setAuthenticated(String musicUserToken) async {
    try {
      final developerToken = await _musicKit.requestDeveloperToken();
      state = AppleMusicAuthenticated(
        developerToken: developerToken,
        musicUserToken: musicUserToken,
      );
    } on Exception catch (e) {
      Log.error(_tag, 'Failed to get developer token', exception: e);
      state = AppleMusicUnauthenticated();
    }
  }
}
