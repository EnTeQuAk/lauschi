import 'dart:async' show unawaited;

import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/spotify/spotify_api.dart';
import 'package:lauschi/features/player/player_backend.dart';
import 'package:lauschi/features/player/player_state.dart';
import 'package:lauschi/features/player/spotify_player_bridge.dart';

const _tag = 'SpotifyBackend';

/// Adapter that controls Spotify playback through both the local SDK
/// and the Web API.
///
/// Commands fire the local SDK first (immediate audio effect, works
/// offline) then the Web API (reliable server-side confirmation).
/// The SDK call is fire-and-forget — we don't wait for it or fail
/// on it. The Web API call is awaited and errors propagate.
class SpotifyBackend extends PlayerBackend {
  SpotifyBackend(this._bridge, this._api);

  final SpotifyPlayerBridge _bridge;
  final SpotifyApi _api;

  @override
  Stream<PlaybackState> get stateStream => _bridge.stateStream;

  @override
  int get currentPositionMs => _bridge.currentState.positionMs;

  @override
  int get currentTrackNumber => _bridge.trackNumber;

  @override
  bool get hasNextTrack => _bridge.nextTracksCount > 0;

  @override
  Future<void> pause() async {
    Log.info(_tag, 'pause');
    // SDK: immediate local audio pause (fire-and-forget).
    unawaited(_bridge.pause());
    // Web API: reliable server-side pause.
    await _api.pause();
  }

  @override
  Future<void> resume() async {
    Log.info(_tag, 'resume');
    final deviceId = _bridge.deviceId;
    // SDK: immediate local audio resume (fire-and-forget).
    unawaited(_bridge.resume());
    // Web API: reliable server-side resume.
    if (deviceId == null) {
      Log.warn(_tag, 'No device ID for Web API resume');
      return;
    }
    await _api.resume(deviceId: deviceId);
  }

  @override
  Future<void> seek(int positionMs) async {
    Log.debug(_tag, 'seek', data: {'positionMs': '$positionMs'});
    // Seek goes through Web API only. Firing both causes competing
    // state_changed events from the SDK that make the progress bar jump.
    await _api.seek(positionMs);
  }

  @override
  Future<void> nextTrack() async {
    Log.info(_tag, 'nextTrack');
    unawaited(_bridge.nextTrack());
    await _api.nextTrack();
  }

  @override
  Future<void> prevTrack() async {
    Log.info(_tag, 'prevTrack');
    unawaited(_bridge.prevTrack());
    await _api.previousTrack();
  }

  @override
  Future<void> stop() async {
    unawaited(_bridge.pause());
    // Best-effort: the Web API pause can fail when the WebView has been
    // killed by iOS (device gone → 404/400) or Spotify is having a bad
    // day (502). We're tearing down this backend anyway, so swallow it.
    try {
      await _api.pause();
    } on Exception catch (e) {
      Log.warn(
        _tag,
        'stop: API pause failed (expected if device gone)',
        data: {'error': '$e'},
      );
    }
  }

  @override
  Future<void> dispose() async {
    // Bridge lifecycle is managed by spotifyPlayerBridgeProvider, not here.
    // SpotifyBackend is created per-play session; the bridge outlives it.
  }
}
