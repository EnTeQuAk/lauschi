import 'dart:async';

import 'package:just_audio/just_audio.dart' as ja;
import 'package:lauschi/core/log.dart';
import 'package:lauschi/features/player/player_backend.dart';
import 'package:lauschi/features/player/player_state.dart';

const _tag = 'DirectPlayer';

/// Plays audio from direct HTTP URLs using just_audio.
///
/// Used for ARD Audiothek and any future non-SDK provider (SRF, local files).
/// No DRM, no SDK, no WebView — just a URL and a player.
class DirectPlayer extends PlayerBackend {
  ja.AudioPlayer? _player;
  final _stateController = StreamController<PlaybackState>.broadcast();
  StreamSubscription<ja.PlayerState>? _playerStateSub;
  StreamSubscription<Duration?>? _durationSub;
  StreamSubscription<Duration>? _positionSub;

  /// Current track metadata set at play time.
  TrackInfo? _currentTrack;
  int _durationMs = 0;
  int _positionMs = 0;
  bool _isPlaying = false;

  /// Stream of playback state changes, matching the Spotify bridge contract.
  @override
  Stream<PlaybackState> get stateStream => _stateController.stream;

  /// Initialize or reuse the audio player.
  ja.AudioPlayer get _audioPlayer {
    if (_player == null) {
      _player = ja.AudioPlayer();
      _listenToPlayer();
    }
    return _player!;
  }

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

    try {
      final duration = await _audioPlayer.setUrl(audioUrl);
      _durationMs = duration?.inMilliseconds ?? 0;

      if (positionMs > 0) {
        await _audioPlayer.seek(Duration(milliseconds: positionMs));
      }
      await _audioPlayer.play();
    } on Exception catch (e) {
      Log.error(_tag, 'Play failed', exception: e);
      _emitState(error: 'Wiedergabe fehlgeschlagen');
    }
  }

  @override
  Future<void> pause() async {
    await _player?.pause();
  }

  @override
  Future<void> resume() async {
    await _player?.play();
  }

  @override
  Future<void> seek(int positionMs) async {
    await _player?.seek(Duration(milliseconds: positionMs));
  }

  @override
  Future<void> stop() async {
    await _player?.stop();
  }

  /// Release resources. Call when switching to a different player backend.
  @override
  Future<void> dispose() async {
    await _playerStateSub?.cancel();
    await _durationSub?.cancel();
    await _positionSub?.cancel();
    await _player?.dispose();
    _player = null;
    await _stateController.close();
  }

  void _listenToPlayer() {
    final player = _player!;

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
      // Don't emit on every position tick — the state change listener
      // handles play/pause transitions. Position is polled by the UI
      // via the periodic save timer in PlayerNotifier.
    });
  }

  void _emitState({String? error}) {
    if (_stateController.isClosed) return;

    _stateController.add(
      PlaybackState(
        isPlaying: _isPlaying,
        isReady: true,
        track: _currentTrack,
        positionMs: _positionMs,
        durationMs: _durationMs,
        // Single-file audio: always track 1, no next tracks.
        trackNumber: 1,
        // Explicit zero: completion detection checks nextTracksCount == 0.
        // ignore: avoid_redundant_argument_values
        nextTracksCount: 0,
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
