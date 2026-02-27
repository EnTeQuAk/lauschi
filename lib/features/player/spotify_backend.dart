import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/spotify/spotify_api.dart';
import 'package:lauschi/features/player/player_backend.dart';
import 'package:lauschi/features/player/player_state.dart';
import 'package:lauschi/features/player/spotify_player_bridge.dart';

const _tag = 'SpotifyBackend';

/// Adapter wrapping [SpotifyPlayerBridge] as a [PlayerBackend].
///
/// Commands go to the local SDK player first. If the SDK call fails
/// (session stale, WebView suspended), pause and resume fall back to
/// the Spotify Web API. Other commands (seek, next, prev) retry via
/// reconnect as before.
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
    try {
      await _bridge.pause();
    } on Exception catch (e) {
      Log.warn(
        _tag,
        'SDK pause failed, falling back to Web API',
        data: {
          'error': '$e',
        },
      );
      await _api.pause();
    }
  }

  @override
  Future<void> resume() async {
    Log.info(_tag, 'resume');
    final deviceId = _bridge.deviceId;
    try {
      await _bridge.resume();
    } on Exception catch (e) {
      if (deviceId == null) rethrow;
      Log.warn(
        _tag,
        'SDK resume failed, falling back to Web API',
        data: {
          'error': '$e',
        },
      );
      await _api.resume(deviceId: deviceId);
    }
  }

  @override
  Future<void> seek(int positionMs) {
    Log.debug(_tag, 'seek $positionMs');
    return _withRetry('seek', () => _bridge.seek(positionMs));
  }

  @override
  Future<void> nextTrack() {
    Log.debug(_tag, 'nextTrack');
    return _withRetry('next', _bridge.nextTrack);
  }

  @override
  Future<void> prevTrack() {
    Log.debug(_tag, 'prevTrack');
    return _withRetry('prev', _bridge.prevTrack);
  }

  @override
  Future<void> stop() async {
    // Spotify SDK has no "stop" — pause is the closest.
    try {
      await _bridge.pause();
    } on Exception {
      await _api.pause();
    }
  }

  @override
  Future<void> dispose() async {
    // Bridge lifecycle is managed by spotifyPlayerBridgeProvider, not here.
    // SpotifyBackend is created per-play session; the bridge outlives it.
  }

  /// Execute a bridge command with one reconnect+retry on failure.
  Future<void> _withRetry(
    String name,
    Future<void> Function() command,
  ) async {
    try {
      await command();
    } on Exception catch (e) {
      Log.error(_tag, '$name failed, reconnecting', exception: e);
      await _bridge.reconnect();
      await command();
    }
  }
}
