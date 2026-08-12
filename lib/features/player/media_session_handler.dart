import 'package:audio_service/audio_service.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/features/player/player_state.dart' as app;

const _tag = 'MediaSession';

/// Whether two media items carry the same notification-visible metadata.
///
/// [MediaItem]'s own `==` compares id only, but the notification also
/// shows title, artist, album, duration, and artwork, so a change in
/// any of those (a duration discovered mid-play, new artwork) must
/// re-emit even when the id is unchanged.
bool mediaItemMetadataEquals(MediaItem? a, MediaItem? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return false;
  return a.id == b.id &&
      a.title == b.title &&
      a.artist == b.artist &&
      a.album == b.album &&
      a.duration == b.duration &&
      a.artUri == b.artUri;
}

/// Proxy [AudioHandler] that exposes playback controls to the system
/// media notification, lock screen, and headset buttons.
///
/// Does not produce audio itself — forwards commands to callbacks
/// and receives state updates from the active player backend.
class MediaSessionHandler extends BaseAudioHandler with SeekHandler {
  /// Last metadata pushed to the notification, so identical metadata is
  /// not re-emitted on every position tick.
  MediaItem? _lastMediaItem;

  /// Called when the system requests play/pause/skip/seek.
  /// Wire these to the player notifier.
  late final void Function() onPlay;
  late final void Function() onPause;
  late final void Function() onSkipNext;
  late final void Function() onSkipPrev;
  late final void Function(Duration position) onSeek;

  @override
  Future<void> play() async {
    Log.debug(_tag, 'System: play');
    onPlay.call();
  }

  @override
  Future<void> pause() async {
    Log.debug(_tag, 'System: pause');
    onPause.call();
  }

  @override
  Future<void> skipToNext() async {
    Log.debug(_tag, 'System: next');
    onSkipNext.call();
  }

  @override
  Future<void> skipToPrevious() async {
    Log.debug(_tag, 'System: prev');
    onSkipPrev.call();
  }

  @override
  Future<void> seek(Duration position) async {
    Log.debug(_tag, 'System: seek ${position.inMilliseconds}ms');
    onSeek.call(position);
  }

  @override
  Future<void> stop() async {
    Log.debug(_tag, 'System: stop');
    onPause.call();
  }

  @override
  Future<void> onTaskRemoved() async {
    // Android: user swiped app away from recents. Pause playback gracefully.
    Log.info(_tag, 'Task removed — pausing playback');
    onPause.call();
    await super.onTaskRemoved();
  }

  @override
  Future<void> onNotificationDeleted() async {
    // Android: user dismissed the media notification.
    Log.info(_tag, 'Notification dismissed — pausing playback');
    onPause.call();
    await super.onNotificationDeleted();
  }

  /// Sync notification state from our [PlaybackState].
  /// [hasNextTrack] controls whether skip-to-next is shown.
  void updateFromAppState(
    app.PlaybackState appState, {
    bool hasNextTrack = false,
  }) {
    final track = appState.track;

    // Update media item (track metadata + artwork) only when it actually
    // changes. Position ticks arrive ~1/sec but the metadata is
    // identical between them; re-pushing it every tick churns the
    // platform notification (~1800 times over a 30-minute episode).
    // Position is carried separately by playbackState.updatePosition.
    if (track != null) {
      final item = MediaItem(
        id: track.uri,
        title: track.name,
        artist: track.artist,
        album: track.album,
        duration: Duration(milliseconds: appState.durationMs),
        artUri:
            track.artworkUrl != null ? Uri.tryParse(track.artworkUrl!) : null,
      );
      if (!mediaItemMetadataEquals(_lastMediaItem, item)) {
        Log.debug(
          _tag,
          'Updating notification metadata',
          data: {'track': track.name, 'hasNext': '$hasNextTrack'},
        );
        _lastMediaItem = item;
        mediaItem.add(item);
      }
    }

    // Build controls list based on playback state and navigation capability.
    final controls = <MediaControl>[
      MediaControl.skipToPrevious,
      if (appState.isPlaying) MediaControl.pause else MediaControl.play,
      if (hasNextTrack) MediaControl.skipToNext,
    ];

    // Compact notification shows prev + play/pause (+ next when available).
    // Index 2 is only valid when skipToNext is in the controls list.
    final compactIndices = hasNextTrack ? const [0, 1, 2] : const [0, 1];

    // Update playback state (controls, position, playing).
    playbackState.add(
      PlaybackState(
        controls: controls,
        systemActions: const {MediaAction.seek},
        androidCompactActionIndices: compactIndices,
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
