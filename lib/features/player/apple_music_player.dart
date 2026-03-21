import 'package:lauschi/core/log.dart';
import 'package:lauschi/features/player/apple_music_webview_bridge.dart';
import 'package:lauschi/features/player/player_backend.dart';
import 'package:lauschi/features/player/player_state.dart';

const _tag = 'AppleMusicPlayer';

/// Plays Apple Music content via MusicKit JS in a WebView.
///
/// Thin wrapper around `AppleMusicWebViewBridge`, same pattern as
/// `SpotifyPlayer` wrapping `SpotifyWebViewBridge`. The bridge manages
/// the WebView and JS communication; this class implements [PlayerBackend].
class AppleMusicPlayer extends PlayerBackend {
  AppleMusicPlayer(this._bridge);

  final AppleMusicWebViewBridge _bridge;

  @override
  Stream<PlaybackState> get stateStream => _bridge.stateStream;

  @override
  int get currentPositionMs => _bridge.currentState.positionMs;

  @override
  int get currentTrackNumber => _bridge.trackIndex + 1;

  @override
  bool get hasNextTrack => _bridge.hasNextTrack;

  /// Start playing an album from a track index.
  Future<void> play({
    required String albumId,
    required TrackInfo trackInfo,
    int trackIndex = 0,
    int positionMs = 0,
  }) async {
    Log.info(
      _tag,
      'Playing',
      data: {'albumId': albumId, 'track': '$trackIndex'},
    );

    await _bridge.playAlbum(albumId, trackIndex: trackIndex);

    // Seek to saved position after playback starts.
    if (positionMs > 0) {
      // Give MusicKit JS a moment to load the queue and start playing
      // before seeking. Without this, the seek arrives before the
      // audio context is ready and gets ignored.
      await Future<void>.delayed(const Duration(seconds: 2));
      await _bridge.seek(positionMs);
    }
  }

  @override
  Future<void> resume() => _bridge.resume();

  @override
  Future<void> pause() => _bridge.pause();

  @override
  Future<void> stop() => _bridge.stop();

  @override
  Future<void> seek(int positionMs) => _bridge.seek(positionMs);

  @override
  Future<void> nextTrack() => _bridge.nextTrack();

  @override
  Future<void> prevTrack() => _bridge.prevTrack();

  @override
  Future<void> dispose() async {
    // Bridge lifecycle is managed by AppleMusicSession, not here.
    // AppleMusicPlayer is created per-play session; the bridge outlives it.
  }
}
