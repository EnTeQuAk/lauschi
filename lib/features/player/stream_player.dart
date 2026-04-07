import 'dart:async';

import 'package:just_audio/just_audio.dart' as ja;
import 'package:lauschi/core/log.dart';
import 'package:lauschi/features/player/player_backend.dart';
import 'package:lauschi/features/player/player_error.dart';
import 'package:lauschi/features/player/player_state.dart';

const _tag = 'StreamPlayer';

/// Outcome of inspecting a player error during retry decision-making.
enum StreamErrorAction {
  /// HTTP 403/404/410 — the URL is gone, surface contentUnavailable.
  contentUnavailable,

  /// Transient error with budget remaining; create a fresh player and try again.
  retry,

  /// Retry budget exhausted; surface playbackFailed.
  giveUp,
}

/// Pure function: classifies a just_audio playback error to decide what to
/// do next. Extracted from the StreamPlayer state machine so the decision
/// can be unit-tested without mocking just_audio's player.
///
/// This is the only piece of StreamPlayer covered by unit tests. The
/// orchestration (creating players, scheduling timers, surfacing state
/// events) is verified by the on-device ARD integration tests, which catch
/// real platform behavior the unit tests can't.
StreamErrorAction classifyStreamError({
  required Object error,
  required int currentAttempt,
  required int maxRetries,
}) {
  // Content errors: don't retry, the URL is gone.
  if (error is ja.PlayerException &&
      (error.code == 403 || error.code == 404 || error.code == 410)) {
    return StreamErrorAction.contentUnavailable;
  }
  // Transient: retry while budget remains.
  if (currentAttempt < maxRetries) {
    return StreamErrorAction.retry;
  }
  // Exhausted.
  return StreamErrorAction.giveUp;
}

/// Plays audio from direct HTTP URLs using just_audio.
///
/// Used for ARD Audiothek content. No DRM, no SDK, no WebView — just a URL
/// and a player.
///
/// `play()` returns once the synchronous setup (setUrl, seek, fire play
/// request) is done. Playback progress and errors arrive via [stateStream].
/// Mid-playback failures (CDN drop, codec error) are caught via the just_audio
/// state stream's onError handler and trigger a retry from the live player
/// position. The retry counter, retry timer, and stop flag live on the
/// instance so [stop] and [dispose] can cancel a pending retry cleanly.
class StreamPlayer extends PlayerBackend {
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

  /// Created in [_attemptPlay], disposed in [_disposePlayer].
  ja.AudioPlayer? _player;

  // ─── Retry state ───────────────────────────────────────────────────
  // Reset at the top of every [play] call. The retry counter shares one
  // budget across setup errors (setUrl/seek throws) and mid-playback
  // errors (state stream onError) — from the user's perspective both
  // are "the network is being weird".

  /// URL captured at play time so retries don't need the original args.
  /// `late` because [_attemptPlay] is only ever called from [play] (which
  /// sets this) or the retry timer (scheduled after a successful [play]).
  late String _currentUrl;

  /// User-requested start position. Falls back to this for setup retries
  /// where the player has no live position to resume from.
  int _initialPositionMs = 0;

  /// Number of retries already consumed. Increments before scheduling.
  int _currentAttempt = 0;

  /// Set by [stop] and [dispose] to abort any pending retry. Reset by [play].
  bool _stopped = false;

  /// Pending retry, scheduled by [_scheduleRetry], cancelled by [stop]/[dispose].
  Timer? _retryTimer;

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
  /// Returns once the synchronous setup is done (setUrl + seek + first
  /// play request fired). Subsequent playback progress and errors arrive
  /// via [stateStream]. Errors thrown during setup are surfaced via the
  /// state stream too — the returned Future does not throw.
  ///
  /// [trackInfo] provides metadata for the lock screen / now-playing bar.
  /// [positionMs] resumes from saved position.
  Future<void> play({
    required String audioUrl,
    required TrackInfo trackInfo,
    int positionMs = 0,
  }) async {
    _stopped = false;
    _currentAttempt = 0;
    _currentUrl = audioUrl;
    _currentTrack = trackInfo;
    _initialPositionMs = positionMs;
    _retryTimer?.cancel();
    _retryTimer = null;

    Log.info(_tag, 'Playing', data: {'url': _truncateUrl(audioUrl)});
    await _attemptPlay(positionMs);
  }

  /// One attempt at playing the current URL. On synchronous (setup)
  /// failure, schedules a retry via [_scheduleRetry]. Mid-playback
  /// failures arrive via the state stream's onError handler in
  /// [_listenToPlayer], not via this method.
  Future<void> _attemptPlay(int positionMs) async {
    if (_stopped) return;

    // Tear down any previous player instance from a prior attempt before
    // creating a new one. Cheap on the first call (no player yet).
    await _disposePlayer();
    if (_stopped) return;

    final player = ja.AudioPlayer();
    _player = player;
    _listenToPlayer(player);

    try {
      final duration = await player.setUrl(_currentUrl);
      _durationMs = duration?.inMilliseconds ?? 0;

      if (positionMs > 0) {
        await player.seek(Duration(milliseconds: positionMs));
      }
    } on ja.PlayerInterruptedException {
      // setUrl was interrupted by another setUrl/dispose. Treat as a
      // user-initiated stop, don't retry.
      Log.info(_tag, 'Setup interrupted');
      return;
    } on Object catch (e) {
      _handleError(e);
      return;
    }

    if (_stopped) return;

    // Fire the play request unawaited. just_audio's play() Future resolves
    // on pause/stop/completion (NOT on play start), so we learn that
    // playback actually started via the state stream's playing=true event,
    // not via this Future. See issue #248.
    unawaited(player.play());
    // play() returns here. Caller is unblocked.
  }

  /// Decide what to do with an error using the pure helper, then act.
  void _handleError(Object e) {
    if (_stopped) return;

    final action = classifyStreamError(
      error: e,
      currentAttempt: _currentAttempt,
      maxRetries: _maxRetries,
    );

    switch (action) {
      case StreamErrorAction.contentUnavailable:
        // Terminal error: clear isPlaying so the emitted state isn't
        // contradictory (`isPlaying: true, error: contentUnavailable`).
        _isPlaying = false;
        final code = e is ja.PlayerException ? e.code : -1;
        final message = e is ja.PlayerException ? (e.message ?? '') : '$e';
        Log.warn(
          _tag,
          'Content unavailable',
          data: {'code': '$code', 'message': message},
        );
        _emitState(error: PlayerError.contentUnavailable);

      case StreamErrorAction.retry:
        // Don't clear isPlaying — we intend to resume after the delay,
        // and the UI shouldn't flicker the controls during a transparent
        // retry of a transient error.
        _currentAttempt++;
        Log.warn(
          _tag,
          'Retrying',
          data: {
            'attempt': '$_currentAttempt/$_maxRetries',
            'error': '$e',
          },
        );
        _scheduleRetry();

      case StreamErrorAction.giveUp:
        // Terminal error: clear isPlaying so the emitted state isn't
        // contradictory (`isPlaying: true, error: playbackFailed`).
        _isPlaying = false;
        Log.warn(
          _tag,
          'Failed after $_maxRetries retries',
          data: {'error': '$e'},
        );
        _emitState(error: PlayerError.playbackFailed);
    }
  }

  /// Schedule a retry of the current URL after [_retryDelay]. The retry
  /// resumes from the live player position if available, else from the
  /// user-requested start position.
  void _scheduleRetry() {
    _retryTimer?.cancel();
    _retryTimer = Timer(_retryDelay, () {
      if (_stopped) return;
      // Live position from the (failed) player, falling back to the
      // original requested position. `livePos == 0` means either the
      // player never produced a position event (setup-time retry) or
      // playback failed before the first 200ms position window — in
      // both cases falling back to `_initialPositionMs` is correct
      // because we never made progress past the user's saved resume
      // point.
      final livePos = _player?.position.inMilliseconds ?? 0;
      final resumePosition = livePos > 0 ? livePos : _initialPositionMs;
      unawaited(_attemptPlay(resumePosition));
    });
  }

  @override
  Future<void> pause() async {
    Log.debug(_tag, 'pause');
    await _player?.pause();
  }

  @override
  Future<void> resume() async {
    Log.debug(_tag, 'resume');
    // just_audio's play() resolves on pause/stop/completion, not on play
    // start. Don't await; observers learn about playback start via the
    // state stream. See issue #248.
    final p = _player;
    if (p != null) unawaited(p.play());
  }

  @override
  Future<void> seek(int positionMs) async {
    Log.debug(_tag, 'seek $positionMs');
    await _player?.seek(Duration(milliseconds: positionMs));
  }

  @override
  Future<void> stop() async {
    Log.debug(_tag, 'stop');
    _stopped = true;
    _retryTimer?.cancel();
    _retryTimer = null;
    await _player?.stop();
  }

  /// Release resources. Call when switching to a different player backend.
  @override
  Future<void> dispose() async {
    Log.debug(_tag, 'dispose');
    _stopped = true;
    _retryTimer?.cancel();
    _retryTimer = null;
    await _disposePlayer();
    await _stateController.close();
  }

  /// Cancel just_audio listeners and dispose the underlying player.
  /// Does NOT close the state controller — that's [dispose]'s job.
  Future<void> _disposePlayer() async {
    await _playerStateSub?.cancel();
    _playerStateSub = null;
    await _durationSub?.cancel();
    _durationSub = null;
    await _positionSub?.cancel();
    _positionSub = null;
    await _player?.dispose();
    _player = null;
  }

  void _listenToPlayer(ja.AudioPlayer player) {
    _playerStateSub = player.playerStateStream.listen(
      (playerState) {
        _isPlaying = playerState.playing;

        // Detect completion: just_audio sets processingState to completed.
        if (playerState.processingState == ja.ProcessingState.completed) {
          Log.info(_tag, 'Playback completed');
          _isPlaying = false;
        }

        _emitState();
      },
      onError: (Object e, StackTrace st) {
        // Mid-playback errors (CDN drop, codec error, network reset) flow
        // through the state stream as errors. Without this handler the
        // existing code silently swallowed them. Hand off to the same
        // retry pipeline as setup errors. Stack trace goes into the
        // structured log for Sentry context.
        Log.warn(
          _tag,
          'Player state stream error',
          data: {'error': '$e', 'stack': '$st'},
        );
        _handleError(e);
      },
    );

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
