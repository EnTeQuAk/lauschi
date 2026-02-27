import 'package:lauschi/core/log.dart';
import 'package:lauschi/features/player/player_backend.dart';
import 'package:lauschi/features/player/player_state.dart';
import 'package:lauschi/features/player/spotify_player_bridge.dart';

const _tag = 'SpotifyBackend';

/// Adapter wrapping [SpotifyPlayerBridge] as a [PlayerBackend].
///
/// Each command gets one reconnect+retry on failure. If the retry also
/// fails, the exception propagates to the caller (PlayerNotifier catches
/// and sets error state).
class SpotifyBackend extends PlayerBackend {
  SpotifyBackend(this._bridge);

  final SpotifyPlayerBridge _bridge;

  @override
  Stream<PlaybackState> get stateStream => _bridge.stateStream;

  @override
  int get currentPositionMs => _bridge.currentState.positionMs;

  @override
  int get currentTrackNumber => _bridge.trackNumber;

  @override
  bool get hasNextTrack => _bridge.nextTracksCount > 0;

  @override
  Future<void> pause() => _withRetry('pause', _bridge.pause);

  @override
  Future<void> resume() => _withRetry('resume', _bridge.resume);

  @override
  Future<void> seek(int positionMs) =>
      _withRetry('seek', () => _bridge.seek(positionMs));

  @override
  Future<void> nextTrack() => _withRetry('next', _bridge.nextTrack);

  @override
  Future<void> prevTrack() => _withRetry('prev', _bridge.prevTrack);

  @override
  Future<void> stop() async {
    // Spotify SDK has no "stop" — pause is the closest.
    await _withRetry('stop', _bridge.pause);
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
