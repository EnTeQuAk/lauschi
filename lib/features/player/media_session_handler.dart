import 'package:audio_service/audio_service.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/features/player/player_state.dart' as app;

const _tag = 'MediaSession';

/// Proxy [AudioHandler] that exposes playback controls to the system
/// media notification, lock screen, and headset buttons.
///
/// Does not produce audio itself — forwards commands to a callback
/// and receives state updates from the Spotify WebView bridge.
class MediaSessionHandler extends BaseAudioHandler with SeekHandler {
  /// Called when the system requests play/pause/skip/seek.
  /// Wire these to the player notifier.
  void Function()? onPlay;
  void Function()? onPause;
  void Function()? onSkipNext;
  void Function()? onSkipPrev;
  void Function(Duration position)? onSeek;

  @override
  Future<void> play() async {
    Log.debug(_tag, 'System: play');
    onPlay?.call();
  }

  @override
  Future<void> pause() async {
    Log.debug(_tag, 'System: pause');
    onPause?.call();
  }

  @override
  Future<void> skipToNext() async {
    Log.debug(_tag, 'System: next');
    onSkipNext?.call();
  }

  @override
  Future<void> skipToPrevious() async {
    Log.debug(_tag, 'System: prev');
    onSkipPrev?.call();
  }

  @override
  Future<void> seek(Duration position) async {
    Log.debug(_tag, 'System: seek ${position.inMilliseconds}ms');
    onSeek?.call(position);
  }

  @override
  Future<void> stop() async {
    Log.debug(_tag, 'System: stop');
    onPause?.call();
  }

  @override
  Future<void> onTaskRemoved() async {
    // Android: user swiped app away from recents. Pause playback gracefully.
    Log.info(_tag, 'Task removed — pausing playback');
    onPause?.call();
    await super.onTaskRemoved();
  }

  @override
  Future<void> onNotificationDeleted() async {
    // Android: user dismissed the media notification.
    Log.info(_tag, 'Notification dismissed — pausing playback');
    onPause?.call();
    await super.onNotificationDeleted();
  }

  /// Sync notification state from our [PlaybackState].
  void updateFromAppState(app.PlaybackState appState) {
    final track = appState.track;

    // Update media item (track metadata + artwork).
    if (track != null) {
      mediaItem.add(
        MediaItem(
          id: track.uri,
          title: track.name,
          artist: track.artist,
          album: track.album,
          duration: Duration(milliseconds: appState.durationMs),
          artUri:
              track.artworkUrl != null ? Uri.tryParse(track.artworkUrl!) : null,
        ),
      );
    }

    // Update playback state (controls, position, playing).
    playbackState.add(
      PlaybackState(
        controls: [
          MediaControl.skipToPrevious,
          if (appState.isPlaying) MediaControl.pause else MediaControl.play,
          MediaControl.skipToNext,
        ],
        systemActions: const {MediaAction.seek},
        androidCompactActionIndices: const [0, 1, 2],
        processingState:
            appState.isReady
                ? AudioProcessingState.ready
                : AudioProcessingState.idle,
        playing: appState.isPlaying,
        updatePosition: Duration(milliseconds: appState.positionMs),
      ),
    );
  }
}
