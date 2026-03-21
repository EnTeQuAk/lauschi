import 'dart:async';

import 'package:flutter/services.dart' show MissingPluginException;
import 'package:lauschi/core/log.dart';
import 'package:lauschi/features/player/player_backend.dart';
import 'package:lauschi/features/player/player_error.dart';
import 'package:lauschi/features/player/player_state.dart';
import 'package:music_kit/music_kit.dart';

const _tag = 'AppleMusicPlayer';

/// Plays Apple Music content via the MusicKit SDK.
///
/// On Android, the forked music_kit plugin (packages/music_kit) provides
/// playbackTime, setPlaybackTime, and currentItemDuration which the
/// upstream plugin left unimplemented.
class AppleMusicPlayer extends PlayerBackend {
  AppleMusicPlayer(this._musicKit);

  final MusicKit _musicKit;

  TrackInfo? _currentTrack;
  int _positionMs = 0;
  int _durationMs = 0;
  bool _isPlaying = false;
  int _trackIndex = 0;
  int _trackCount = 0;

  Timer? _positionTimer;
  StreamSubscription<MusicPlayerState>? _playerStateSub;
  StreamSubscription<MusicPlayerQueue>? _queueSub;
  int? _pendingSeekMs;
  final _stateController = StreamController<PlaybackState>.broadcast();

  @override
  Stream<PlaybackState> get stateStream => _stateController.stream;

  @override
  int get currentPositionMs => _positionMs;

  @override
  int get currentTrackNumber => _trackIndex + 1;

  @override
  bool get hasNextTrack => _trackIndex < _trackCount - 1;

  /// Pre-prepare an album without starting playback.
  ///
  /// Warms up the Apple Music SDK's DRM pipeline and streaming
  /// connection. Call this early (e.g., when the user opens a tile
  /// detail screen) so that when they tap play, the buffering is
  /// already done or nearly done.
  /// Pre-prepare an album without starting playback.
  ///
  /// Warms up the Apple Music SDK's DRM pipeline and streaming
  /// connection. Call early (e.g., when the user opens a tile detail
  /// screen) so that when they tap play, buffering is already done.
  Future<void> warmUp(String albumId) async {
    Log.info(_tag, 'Warming up', data: {'albumId': albumId});
    try {
      await _musicKit.setQueue(
        'albums',
        item: <String, dynamic>{'id': albumId},
        autoplay: false,
      );
    } on Exception catch (e) {
      Log.debug(_tag, 'Warm-up failed (non-critical)', data: {'error': '$e'});
    }
  }

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

      // Queue the album. The SDK handles track ordering and next/prev
      // within the album automatically. Single-track queuing was tested
      // but doesn't reduce the ~30-60s DRM/buffering latency (that's
      // in the Apple Music app's IPC pipeline, not queue loading).
      await _musicKit.setQueue(
        'albums',
        item: <String, dynamic>{'id': albumId},
      );
      await _musicKit.play();

      // Skip to target track after queue loads.
      if (trackIndex > 0) {
        for (var i = 0; i < trackIndex; i++) {
          await _musicKit.skipToNextEntry();
        }
      }

      _startPositionPolling();

      if (positionMs > 0) {
        _pendingSeekMs = positionMs;
      }
    } on Exception catch (e) {
      Log.error(_tag, 'Play failed', exception: e);
      _emitState(error: PlayerError.playbackFailed);
    }
  }

  @override
  Future<void> resume() async {
    await _musicKit.play();
    _startPositionPolling();
  }

  @override
  Future<void> pause() async {
    Log.debug(_tag, 'pause');
    await _musicKit.pause();
    _stopPositionPolling();
  }

  @override
  Future<void> stop() async {
    await _musicKit.stop();
  }

  @override
  Future<void> dispose() async {
    _stopPositionPolling();
    await _playerStateSub?.cancel();
    _playerStateSub = null;
    await _queueSub?.cancel();
    _queueSub = null;
    try {
      await _musicKit.stop();
    } on Exception {
      // Ignore stop errors during teardown.
    }
    if (!_stateController.isClosed) {
      await _stateController.close();
    }
  }

  @override
  Future<void> seek(int positionMs) => _seekMs(positionMs);

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

  // ── State listening ───────────────────────────────────────────────

  void _listenToState() {
    _playerStateSub = _musicKit.onMusicPlayerStateChanged.listen((mkState) {
      final wasPlaying = _isPlaying;
      _isPlaying = mkState.playbackStatus == MusicPlayerPlaybackStatus.playing;

      // Apply pending seek when playback first starts.
      if (_isPlaying && !wasPlaying && _pendingSeekMs != null) {
        final seekTo = _pendingSeekMs!;
        _pendingSeekMs = null;
        Future.delayed(
          const Duration(seconds: 3),
          () => _seekMs(seekTo),
        );
      }

      _emitState();
    });

    _queueSub = _musicKit.onPlayerQueueChanged.listen((queue) {
      _trackCount = queue.entries.length;
      final current = queue.currentEntry;
      if (current != null) {
        final idx = queue.entries.indexWhere((e) => e.id == current.id);
        if (idx >= 0) _trackIndex = idx;

        _currentTrack = TrackInfo(
          uri: 'apple_music:track:${current.id}',
          name: current.title,
          artist: current.subtitle ?? _currentTrack?.artist,
          artworkUrl: current.artwork?.url ?? _currentTrack?.artworkUrl,
        );

        // Duration from queue entry metadata.
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

  // ── Position polling ──────────────────────────────────────────────

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

      if (_durationMs == 0) {
        final duration = await _musicKit.currentItemDuration;
        if (duration > 0) {
          _durationMs = (duration * 1000).round();
        }
      }

      _emitState();
    } on MissingPluginException {
      // Shouldn't happen with the forked plugin.
      Log.warn(_tag, 'playbackTime not available, disabling polling');
      _stopPositionPolling();
    } on Exception catch (e) {
      Log.debug(_tag, 'Position poll failed', data: {'error': '$e'});
    }
  }

  // ── Seek ──────────────────────────────────────────────────────────

  Future<void> _seekMs(int positionMs) async {
    final seconds = positionMs / 1000.0;
    try {
      await _musicKit.setPlaybackTime(seconds);
      _positionMs = positionMs;
      _emitState();
    } on Exception catch (e) {
      Log.warn(
        _tag,
        'Seek failed',
        data: {'positionMs': '$positionMs', 'error': '$e'},
      );
    }
  }

  // ── State emission ────────────────────────────────────────────────

  void _emitState({PlayerError? error}) {
    if (_stateController.isClosed) return;
    _stateController.add(
      PlaybackState(
        isReady: true,
        isPlaying: _isPlaying,
        track: _currentTrack,
        positionMs: _positionMs,
        durationMs: _durationMs,
        error: error,
      ),
    );
  }
}
