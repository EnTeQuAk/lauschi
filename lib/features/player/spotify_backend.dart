import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/spotify/spotify_api.dart';
import 'package:lauschi/features/player/player_backend.dart';
import 'package:lauschi/features/player/player_state.dart';
import 'package:lauschi/features/player/spotify_player_bridge.dart';

const _tag = 'SpotifyBackend';

/// Adapter that controls Spotify playback via the Web API.
///
/// All commands (pause, resume, seek, next, prev) go through the
/// Spotify Web API as the primary path. The local SDK in the WebView
/// is used for state observation only — the bridge's `stateStream`
/// delivers playback events, but commands are never routed through JS.
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
    await _api.pause();
  }

  @override
  Future<void> resume() async {
    Log.info(_tag, 'resume');
    final deviceId = _bridge.deviceId;
    if (deviceId == null) {
      Log.warn(_tag, 'No device ID for resume');
      return;
    }
    await _api.resume(deviceId: deviceId);
  }

  @override
  Future<void> seek(int positionMs) async {
    Log.debug(_tag, 'seek', data: {'positionMs': '$positionMs'});
    await _api.seek(positionMs);
  }

  @override
  Future<void> nextTrack() async {
    Log.info(_tag, 'nextTrack');
    await _api.nextTrack();
  }

  @override
  Future<void> prevTrack() async {
    Log.info(_tag, 'prevTrack');
    await _api.previousTrack();
  }

  @override
  Future<void> stop() async {
    await _api.pause();
  }

  @override
  Future<void> dispose() async {
    // Bridge lifecycle is managed by spotifyPlayerBridgeProvider, not here.
    // SpotifyBackend is created per-play session; the bridge outlives it.
  }
}
