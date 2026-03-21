import 'dart:async';

import 'package:lauschi/core/log.dart';
import 'package:lauschi/features/player/player_backend.dart';
import 'package:lauschi/features/player/player_state.dart';
import 'package:music_kit/music_kit.dart';

const _tag = 'AppleMusicPlayer';

/// Plays Apple Music content via the native MediaPlayerController.
///
/// Uses Apple's Android playback SDK (com.apple.android.music.playback)
/// through the forked music_kit Flutter plugin. Auth is handled by the
/// web flow (browser → MusicKit JS → deep link); the web MUT is passed
/// to the native SDK via setMusicUserToken().
///
/// This avoids WebView DRM limitations (Widevine L3 only on many Android
/// devices causes CONTENT_EQUIVALENT errors with MusicKit JS).
class AppleMusicPlayer extends PlayerBackend {
  AppleMusicPlayer(this._musicKit);

  final MusicKit _musicKit;

  final _stateController = StreamController<PlaybackState>.broadcast();
  StreamSubscription<MusicPlayerState>? _stateSub;
  StreamSubscription<MusicPlayerQueue>? _queueSub;

  PlaybackState _state = const PlaybackState();
  int _trackIndex = 0;
  int _totalTracks = 0;
  Timer? _positionTimer;

  @override
  Stream<PlaybackState> get stateStream => _stateController.stream;

  @override
  int get currentPositionMs => _state.positionMs;

  @override
  int get currentTrackNumber => _trackIndex + 1;

  @override
  bool get hasNextTrack => _trackIndex < _totalTracks - 1;

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

    _listenToState();
    _listenToQueue();

    // Queue the album via native SDK.
    await _musicKit.setQueue(
      'albums',
      item: {'id': albumId},
      autoplay: true,
    );

    // If starting from a specific track, skip to it.
    // The native SDK queues from track 0 by default.
    if (trackIndex > 0) {
      // Give the player a moment to prepare the queue.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      for (var i = 0; i < trackIndex; i++) {
        await _musicKit.skipToNextEntry();
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }

    // Seek to saved position after playback starts.
    if (positionMs > 0) {
      await Future<void>.delayed(const Duration(seconds: 1));
      await _musicKit.setPlaybackTime(positionMs / 1000.0);
    }
  }

  @override
  Future<void> resume() => _musicKit.play();

  @override
  Future<void> pause() => _musicKit.pause();

  @override
  Future<void> stop() => _musicKit.stop();

  @override
  Future<void> seek(int positionMs) =>
      _musicKit.setPlaybackTime(positionMs / 1000.0);

  @override
  Future<void> nextTrack() => _musicKit.skipToNextEntry();

  @override
  Future<void> prevTrack() => _musicKit.skipToPreviousEntry();

  @override
  Future<void> dispose() async {
    _positionTimer?.cancel();
    await _stateSub?.cancel();
    await _queueSub?.cancel();
    _stateSub = null;
    _queueSub = null;
    await _stateController.close();
  }

  // ── State listeners ─────────────────────────────────────────────────

  void _listenToState() {
    _stateSub?.cancel();
    _stateSub = _musicKit.onMusicPlayerStateChanged.listen((playerState) {
      final isPlaying =
          playerState.playbackStatus == MusicPlayerPlaybackStatus.playing;
      final isPaused =
          playerState.playbackStatus == MusicPlayerPlaybackStatus.paused;

      _updateState(_state.copyWith(isPlaying: isPlaying, isReady: true));

      if (isPlaying) {
        _startPositionPolling();
      } else {
        _stopPositionPolling();
      }

      if (isPlaying || isPaused) {
        // Poll position once immediately on state change.
        unawaited(_pollPosition());
      }
    });
  }

  void _listenToQueue() {
    _queueSub?.cancel();
    _queueSub = _musicKit.onPlayerQueueChanged.listen((queue) {
      _totalTracks = queue.entries.length;

      final current = queue.currentEntry;
      if (current != null) {
        final idx = queue.entries.indexWhere((e) => e.id == current.id);
        if (idx >= 0) _trackIndex = idx;

        // The native SDK artwork URL may use Apple's {w}x{h} template format
        // or be empty. Resolve to a concrete URL or fall back to empty string.
        var artUrl = current.artwork?.url ?? '';
        if (artUrl.contains('{w}') || artUrl.contains('{h}')) {
          artUrl = artUrl.replaceAll('{w}', '300').replaceAll('{h}', '300');
        }
        // Only use URLs with a valid host (the media session notification
        // crashes on relative paths or empty URIs).
        final artUri = Uri.tryParse(artUrl);
        if (artUri == null || !artUri.hasScheme || !artUri.hasAuthority) {
          artUrl = '';
        }

        _updateState(
          _state.copyWith(
            track: TrackInfo(
              uri: 'apple_music:track:${current.id}',
              name: current.title,
              artist: current.subtitle,
              artworkUrl: artUrl,
            ),
          ),
        );

        Log.info(
          _tag,
          'Track changed',
          data: {
            'track': current.title,
            'index': '$_trackIndex',
            'total': '$_totalTracks',
          },
        );
      }
    });
  }

  void _startPositionPolling() {
    _stopPositionPolling();
    _positionTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => unawaited(_pollPosition()),
    );
  }

  void _stopPositionPolling() {
    _positionTimer?.cancel();
    _positionTimer = null;
  }

  Future<void> _pollPosition() async {
    try {
      final posSeconds = await _musicKit.playbackTime;
      final durSeconds = await _musicKit.currentItemDuration;
      _updateState(
        _state.copyWith(
          positionMs: (posSeconds * 1000).round(),
          durationMs: (durSeconds * 1000).round(),
        ),
      );
    } on Exception {
      // Player might not be ready.
    }
  }

  void _updateState(PlaybackState newState) {
    if (_stateController.isClosed) return;
    _state = newState;
    _stateController.add(newState);
  }
}
