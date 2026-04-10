import 'package:lauschi/features/player/player_state.dart';

/// Abstraction over playback control for different audio providers.
///
/// Implementations: SpotifyPlayer (WebView SDK), StreamPlayer
/// (just_audio for ARD), AppleMusicPlayer (MusicKit SDK).
///
/// `PlayerNotifier` delegates pause/resume/seek to the active backend
/// without branching on provider type. The "start playing" step differs
/// per provider and is handled in `PlayerNotifier.playCard`.
abstract class PlayerBackend {
  /// Stream of playback state updates from this backend.
  Stream<PlaybackState> get stateStream;

  /// Current playback position in milliseconds.
  ///
  /// Queried directly by the position save timer because the provider
  /// state stream may lag behind actual playback position.
  int get currentPositionMs;

  /// 1-based position of the current track within the album.
  /// Single-file backends (StreamPlayer) always return 1.
  int get currentTrackNumber;

  /// Whether there are more tracks after the current one.
  /// Used for album completion detection and media session controls.
  /// Single-file backends always return false.
  bool get hasNextTrack;

  Future<void> pause();
  Future<void> resume();
  Future<void> seek(int positionMs);
  Future<void> stop();
  Future<void> dispose();

  /// Multi-track navigation. No-op for single-file backends.
  Future<void> nextTrack() async {}
  Future<void> prevTrack() async {}
}

/// Shared interface for Apple Music backends (native MusicKit on iOS,
/// ExoPlayer + DRM on Android). Both accept the same play() parameters;
/// this mixin avoids duplicating the call site in PlayerNotifier.
mixin AlbumPlayback on PlayerBackend {
  Future<void> play({
    required String albumId,
    required TrackInfo trackInfo,
    int trackIndex = 0,
    int positionMs = 0,
  });
}
