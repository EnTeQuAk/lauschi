import 'package:lauschi/features/player/player_state.dart';

/// Abstraction over playback control for different audio providers.
///
/// A backend reports the end of the card's content explicitly, with
/// `PlaybackState.isFinished`, in whatever way its provider signals it.
/// The player never infers the end from positions.
///
/// Implementations: SpotifyPlayer (WebView SDK), StreamPlayer
/// (just_audio for ARD), AppleMusicBackend subclasses (MusicKit SDK).
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

  /// Time from the start of the card's content to the current position,
  /// across all tracks.
  int get elapsedMs;

  /// Duration of the card's whole content, 0 when unknown.
  int get contentDurationMs;

  /// Whether there are more tracks after the current one, i.e. whether
  /// the current track is the last one. Single-file backends always
  /// return false.
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

/// [PlayerBackend.elapsedMs] for a multi-track album: the durations of the tracks
/// before the 1-based [trackNumber], plus [positionMs] into it.
int elapsedAcrossTracks(
  List<int> trackDurationsMs, {
  required int trackNumber,
  required int positionMs,
}) {
  final before = trackDurationsMs.take((trackNumber - 1).clamp(0, 9999));
  return before.fold(0, (sum, d) => sum + d) + positionMs;
}
