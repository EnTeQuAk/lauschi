import 'package:lauschi/features/player/player_state.dart';

/// Abstraction over playback control for different audio providers.
///
/// Each provider (Spotify SDK, just_audio, Apple Music, etc.) extends
/// this class. `PlayerNotifier` delegates pause/resume/seek to the
/// active backend without branching on provider type.
///
/// The "start playing" step differs per provider (Spotify needs a device ID
/// and Web API call, direct needs an audio URL) — that's handled in
/// `PlayerNotifier.playCard`, not here.
abstract class PlayerBackend {
  /// Stream of playback state updates from this backend.
  Stream<PlaybackState> get stateStream;

  Future<void> pause();
  Future<void> resume();
  Future<void> seek(int positionMs);
  Future<void> stop();
  Future<void> dispose();

  /// Multi-track navigation — no-op for single-file backends.
  Future<void> nextTrack() async {}
  Future<void> prevTrack() async {}
}
