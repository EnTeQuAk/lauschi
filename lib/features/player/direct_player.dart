import 'dart:async';

import 'package:just_audio/just_audio.dart' as ja;
import 'package:lauschi/core/log.dart';
import 'package:lauschi/features/player/player_backend.dart';
import 'package:lauschi/features/player/player_error.dart';
import 'package:lauschi/features/player/player_state.dart';

const _tag = 'DirectPlayer';

/// Plays audio from direct HTTP URLs using just_audio.
///
/// Used for ARD Audiothek content. No DRM, no SDK, no WebView — just a URL
/// and a player.
class DirectPlayer extends PlayerBackend {
  final _stateController = StreamController<PlaybackState>.broadcast();
  StreamSubscription<ja.PlayerState>? _playerStateSub;
  StreamSubscription<Duration?>? _durationSub;
  StreamSubscription<Duration>? _positionSub;

  /// Current track metadata set at play time.
  TrackInfo? _currentTrack;
  int _durationMs = 0;
  int _positionMs = 0;
  bool _isPlaying = false;

  /// Last time we emitted a position update. Throttles to ~1/sec
  /// to avoid flooding _onStateChange on every just_audio tick (~200ms).
  DateTime _lastPositionEmit = DateTime(0);

  /// Created in [play], disposed in [dispose].
  ja.AudioPlayer? _player;

  @override
  int get currentPositionMs => _positionMs;

  /// Single-file audio: always track 1.
  @override
  int get currentTrackNumber => 1;

  /// Single-file audio: no next tracks.
  @override
  bool get hasNextTrack => false;

  @override
  Stream<PlaybackState> get stateStream => _stateController.stream;

  /// Max retries for transient errors (CDN hiccups, timeouts). See #224.
  static const _maxRetries = 2;
  static const _retryDelay = Duration(seconds: 2);

  /// Play audio from a direct HTTP URL.
  ///
  /// [trackInfo] provides metadata for the lock screen / now-playing bar.
  /// [positionMs] resumes from saved position.
  Future<void> play({
    required String audioUrl,
    required TrackInfo trackInfo,
    int positionMs = 0,
  }) async {
    _currentTrack = trackInfo;
    Log.info(_tag, 'Playing', data: {'url': _truncateUrl(audioUrl)});

    for (var attempt = 0; attempt <= _maxRetries; attempt++) {
      try {
        final player = ja.AudioPlayer();
        _player = player;
        _listenToPlayer(player);
        final duration = await player.setUrl(audioUrl);
        _durationMs = duration?.inMilliseconds ?? 0;

        if (positionMs > 0) {
          await player.seek(Duration(milliseconds: positionMs));
        }
        await player.play();
        return; // Success.
      } on ja.PlayerException catch (e) {
        // HTTP 404/410/403: content gone, don't retry.
        final code = e.code;
        if (_isContentError(code)) {
          Log.warn(
            _tag,
            'Content unavailable',
            data: {'code': '$code', 'message': e.message ?? ''},
          );
          _emitState(error: PlayerError.contentUnavailable);
          return;
        }
        // Transient error (5xx, timeout): retry if attempts remain.
        if (attempt < _maxRetries) {
          Log.warn(
            _tag,
            'Transient error, retrying',
            data: {
              'attempt': '${attempt + 1}/$_maxRetries',
              'code': '$code',
            },
          );
          await _player?.dispose();
          _player = null;
          await Future<void>.delayed(_retryDelay);
          continue;
        }
        Log.warn(
          _tag,
          'Player error after $_maxRetries retries',
          data: {'code': '$code', 'message': e.message ?? ''},
        );
        _emitState(error: PlayerError.playbackFailed);
        return;
      } on ja.PlayerInterruptedException {
        // Playback interrupted (e.g. another audio source started).
        Log.info(_tag, 'Playback interrupted');
        return;
      } on Exception catch (e) {
        if (attempt < _maxRetries) {
          Log.warn(
            _tag,
            'Play failed, retrying',
            data: {'attempt': '${attempt + 1}/$_maxRetries', 'error': '$e'},
          );
          await _player?.dispose();
          _player = null;
          await Future<void>.delayed(_retryDelay);
          continue;
        }
        Log.error(_tag, 'Play failed after $_maxRetries retries', exception: e);
        _emitState(error: PlayerError.playbackFailed);
        return;
      }
    }
  }

  /// HTTP error codes that mean content is gone (don't retry).
  static bool _isContentError(int code) =>
      code == 403 || code == 404 || code == 410;

  @override
  Future<void> pause() async {
    Log.debug(_tag, 'pause');
    await _player?.pause();
  }

  @override
  Future<void> resume() async {
    Log.debug(_tag, 'resume');
    await _player?.play();
  }

  @override
  Future<void> seek(int positionMs) async {
    Log.debug(_tag, 'seek $positionMs');
    await _player?.seek(Duration(milliseconds: positionMs));
  }

  @override
  Future<void> stop() async {
    Log.debug(_tag, 'stop');
    await _player?.stop();
  }

  /// Release resources. Call when switching to a different player backend.
  @override
  Future<void> dispose() async {
    Log.debug(_tag, 'dispose');
    await _playerStateSub?.cancel();
    await _durationSub?.cancel();
    await _positionSub?.cancel();
    await _player?.dispose();
    _player = null;
    await _stateController.close();
  }

  void _listenToPlayer(ja.AudioPlayer player) {
    _playerStateSub = player.playerStateStream.listen((playerState) {
      _isPlaying = playerState.playing;

      // Detect completion: just_audio sets processingState to completed.
      if (playerState.processingState == ja.ProcessingState.completed) {
        Log.info(_tag, 'Playback completed');
        _isPlaying = false;
      }

      _emitState();
    });

    _durationSub = player.durationStream.listen((duration) {
      _durationMs = duration?.inMilliseconds ?? 0;
      _emitState();
    });

    _positionSub = player.positionStream.listen((position) {
      _positionMs = position.inMilliseconds;
      // Throttle position emissions to ~1/sec. just_audio fires every
      // ~200ms but the UI only needs 1/sec updates, and each emission
      // triggers _onStateChange (wakelock, media session, timer guard).
      final now = DateTime.now();
      if (now.difference(_lastPositionEmit).inMilliseconds >= 1000) {
        _lastPositionEmit = now;
        _emitState();
      }
    });
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

  /// Truncate URL for logging (don't log full CDN paths).
  static String _truncateUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return url;
    final path = uri.path;
    return '${uri.host}${path.length > 40 ? '${path.substring(0, 40)}…' : path}';
  }
}
