import 'dart:async' show unawaited;

import 'package:lauschi/core/apple_music/apple_music_api.dart';
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

class AppleMusicAuthenticated extends AppleMusicState {}

// ---------------------------------------------------------------------------
// AppleMusicSession provider
// ---------------------------------------------------------------------------

/// Central provider for Apple Music auth and playback.
///
/// The MusicKit plugin handles credentials (JWT from AndroidManifest),
/// token persistence (SharedPreferences), and controller lifecycle
/// internally. This session just manages the auth state visible to
/// the rest of the app.
@Riverpod(keepAlive: true)
class AppleMusicSession extends _$AppleMusicSession {
  final MusicKit _musicKit = MusicKit();
  late final AppleMusicApi _api = AppleMusicApi(_musicKit);

  @override
  AppleMusicState build() {
    unawaited(_init());
    return AppleMusicLoading();
  }

  // ── Public accessors ────────────────────────────────────────────────

  MusicKit get musicKit => _musicKit;

  /// REST API client for catalog browsing.
  AppleMusicApi get api => _api;

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
      if (status is MusicAuthorizationStatusAuthorized) {
        _api.init();
        state = AppleMusicAuthenticated();
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

      if (result is MusicAuthorizationStatusAuthorized) {
        _api.init();
        state = AppleMusicAuthenticated();
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

  /// Disconnect (clear native tokens).
  Future<void> disconnect() async {
    // The plugin persists tokens in SharedPreferences.
    // To truly disconnect, we'd need to clear those. For now,
    // just update the Dart state. A full disconnect would require
    // a plugin method to clear stored tokens.
    state = AppleMusicUnauthenticated();
    Log.info(_tag, 'Disconnected');
  }

  /// Re-check auth status (e.g. after app resume).
  Future<void> recheckAuth({bool fromConnect = false}) async {
    if (!fromConnect && state is AppleMusicLoading) return;
    try {
      final status = await _musicKit.authorizationStatus;
      if (status is MusicAuthorizationStatusAuthorized) {
        if (state is! AppleMusicAuthenticated) {
          _api.init();
          state = AppleMusicAuthenticated();
          Log.info(_tag, 'Authorized on recheck');
        }
      } else if (state is! AppleMusicUnauthenticated) {
        state = AppleMusicUnauthenticated();
      }
    } on Exception catch (e) {
      Log.warn(_tag, 'Auth recheck failed', data: {'error': '$e'});
    }
  }

  /// Cancel an in-progress connect attempt.
  void cancelConnect() {
    if (state is AppleMusicLoading) {
      state = AppleMusicUnauthenticated();
      Log.info(_tag, 'Connect cancelled');
    }
  }
}
