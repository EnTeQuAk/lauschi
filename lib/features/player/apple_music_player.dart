import 'dart:async';

import 'package:lauschi/core/apple_music/apple_music_seek.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/features/player/player_backend.dart';
import 'package:lauschi/features/player/player_error.dart';
import 'package:lauschi/features/player/player_state.dart';
import 'package:music_kit/music_kit.dart';

const _tag = 'AppleMusicPlayer';

/// Plays Apple Music content via the MusicKit SDK.
///
/// Works on both iOS (native MusicKit framework) and Android (Apple's
/// MusicKit Android SDK). User needs an Apple Music subscription.
class AppleMusicPlayer extends PlayerBackend {
  AppleMusicPlayer(this._musicKit);

  final MusicKit _musicKit;
  final _stateController = StreamController<PlaybackState>.broadcast();

  StreamSubscription<MusicPlayerState>? _playerStateSub;
  StreamSubscription<MusicPlayerQueue>? _queueSub;

  TrackInfo? _currentTrack;
  int _positionMs = 0;
  int _durationMs = 0;
  bool _isPlaying = false;
  int _trackIndex = 0;
  int _trackCount = 0;

  /// Poll timer for playback position. MusicKit doesn't stream position
  /// updates like just_audio; we poll `playbackTime` at ~1Hz.
  Timer? _positionTimer;

  @override
  int get currentPositionMs => _positionMs;

  @override
  int get currentTrackNumber => _trackIndex + 1;

  @override
  bool get hasNextTrack => _trackIndex < _trackCount - 1;

  @override
  Stream<PlaybackState> get stateStream => _stateController.stream;

  /// Play an Apple Music album (Hörspiel) by its catalog ID.
  ///
  /// [albumId] is the Apple Music catalog ID (e.g. "1440833098").
  /// [trackInfo] provides metadata for the now-playing bar.
  /// [trackIndex] starts playback at a specific track (0-based).
  /// [positionMs] resumes from saved position within that track.
  Future<void> play({
    required String albumId,
    required TrackInfo trackInfo,
    int trackIndex = 0,
    int positionMs = 0,
  }) async {
    _currentTrack = trackInfo;
    _trackIndex = trackIndex;
    Log.info(
      _tag,
      'Playing',
      data: {'albumId': albumId, 'track': '$trackIndex'},
    );

    try {
      _listenToState();

      // Set the album as the playback queue.
      await _musicKit.setQueue(
        'albums',
        item: <String, dynamic>{'id': albumId},
      );

      // Skip to the target track if not the first one.
      for (var i = 0; i < trackIndex; i++) {
        await _musicKit.skipToNextEntry();
      }

      await _musicKit.play();

      // Seek within the track if resuming.
      if (positionMs > 0) {
        // MusicKit uses seconds (double), not milliseconds.
        // TODO(#230): verify seek-after-play timing on both platforms.
        await Future<void>.delayed(const Duration(milliseconds: 500));
        await _seekSeconds(positionMs / 1000.0);
      }

      _startPositionPolling();
    } on Exception catch (e) {
      Log.error(_tag, 'Play failed', exception: e);
      _trackIndex = 0;
      _currentTrack = null;
      _isPlaying = false;
      _emitState(error: PlayerError.playbackFailed);
    }
  }

  @override
  Future<void> pause() async {
    Log.debug(_tag, 'pause');
    await _musicKit.pause();
  }

  @override
  Future<void> resume() async {
    Log.debug(_tag, 'resume');
    await _musicKit.play();
  }

  @override
  Future<void> seek(int positionMs) async {
    Log.debug(_tag, 'seek $positionMs');
    await _seekSeconds(positionMs / 1000.0);
  }

  @override
  Future<void> nextTrack() async {
    Log.debug(_tag, 'nextTrack');
    await _musicKit.skipToNextEntry();
  }

  @override
  Future<void> prevTrack() async {
    Log.debug(_tag, 'prevTrack');
    await _musicKit.skipToPreviousEntry();
  }

  @override
  Future<void> stop() async {
    Log.debug(_tag, 'stop');
    await _musicKit.stop();
    _stopPositionPolling();
  }

  @override
  Future<void> dispose() async {
    Log.debug(_tag, 'dispose');
    _stopPositionPolling();
    await _playerStateSub?.cancel();
    await _queueSub?.cancel();
    await _musicKit.stop();
    await _stateController.close();
  }

  void _listenToState() {
    _playerStateSub = _musicKit.onMusicPlayerStateChanged.listen((mkState) {
      _isPlaying = mkState.playbackStatus == MusicPlayerPlaybackStatus.playing;
      _emitState();
    });

    _queueSub = _musicKit.onPlayerQueueChanged.listen((queue) {
      _trackCount = queue.entries.length;
      final current = queue.currentEntry;
      if (current != null) {
        final idx = queue.entries.indexWhere((e) => e.id == current.id);
        if (idx >= 0) _trackIndex = idx;

        // Update track info from queue metadata.
        _currentTrack = TrackInfo(
          uri: 'apple_music:track:${current.id}',
          name: current.title,
          artist: current.subtitle ?? _currentTrack?.artist,
          artworkUrl: current.artwork?.url ?? _currentTrack?.artworkUrl,
        );

        // Try to get duration from the queue entry's item metadata.
        final itemData = current.item;
        if (itemData != null) {
          final durationInMs = itemData['durationInMillis'] as int?;
          if (durationInMs != null && durationInMs > 0) {
            _durationMs = durationInMs;
          }
        }
      }
      _emitState();
    });
  }

  void _startPositionPolling() {
    _stopPositionPolling();
    _positionTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _pollPosition(),
    );
  }

  void _stopPositionPolling() {
    _positionTimer?.cancel();
    _positionTimer = null;
  }

  Future<void> _pollPosition() async {
    try {
      final seconds = await _musicKit.playbackTime;
      _positionMs = (seconds * 1000).round();
      _emitState();
    } on Exception catch (e) {
      // Position polling can fail when playback stops naturally.
      Log.debug(_tag, 'Position poll failed', data: {'error': '$e'});
    }
  }

  Future<void> _seekSeconds(double seconds) async {
    // WORKAROUND: music_kit plugin (v1.3.0) doesn't expose seek.
    // Uses a direct platform channel. Falls back to logging a warning
    // if the native side isn't ready. See #230.
    await seekAppleMusic(seconds);
  }

  void _emitState({PlayerError? error}) {
    if (_stateController.isClosed) return;

    _stateController.add(
      PlaybackState(
        isPlaying: _isPlaying,
        isReady: true,
        track: _currentTrack,
        positionMs: _positionMs,
        durationMs: _durationMs,
        error: error,
      ),
    );
  }
}
