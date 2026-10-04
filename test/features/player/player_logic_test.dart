import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/features/player/player_backend.dart';
import 'package:lauschi/features/player/player_provider.dart';
import 'package:lauschi/features/player/player_state.dart';

/// Records the order of teardown calls without any native players.
class _RecordingBackend extends PlayerBackend {
  final calls = <String>[];
  final _controller = StreamController<PlaybackState>.broadcast();

  @override
  Stream<PlaybackState> get stateStream => _controller.stream;
  @override
  int get currentPositionMs => 0;
  @override
  int get currentTrackNumber => 1;
  @override
  bool get hasNextTrack => false;
  @override
  int get elapsedMs => 0;
  @override
  int get contentDurationMs => 0;
  @override
  Future<void> pause() async {}
  @override
  Future<void> resume() async {}
  @override
  Future<void> seek(int positionMs) async {}
  @override
  Future<void> stop() async => calls.add('stop');
  @override
  Future<void> dispose() async {
    calls.add('dispose');
    await _controller.close();
  }
}

void main() {
  group('teardownBackend', () {
    test('cancels the subscription, then stops, then disposes', () async {
      // A backend torn down on card switch must be fully released, not
      // just stopped: stop() alone leaks StreamPlayer's native player
      // and Apple Music's shared-stream subscription (which can then
      // hijack playback by advancing a stale album). stop() must run
      // before dispose() so audio halts before resources go.
      final backend = _RecordingBackend();
      final sub = backend.stateStream.listen((_) {});

      await teardownBackend(backend, sub);

      expect(backend.calls, ['stop', 'dispose']);
    });

    test('handles a null subscription', () async {
      final backend = _RecordingBackend();
      await teardownBackend(backend, null);
      expect(backend.calls, ['stop', 'dispose']);
    });
  });

  group('shouldIgnoreRepeatPlay', () {
    // A kid re-tapping the glowing card must not restart the backend.
    test('ignores a re-tap of the card that is already playing', () {
      expect(
        shouldIgnoreRepeatPlay(
          cardId: 'a',
          activeCardId: 'a',
          isPlaying: true,
          forceReplay: false,
        ),
        isTrue,
      );
    });

    // The regression this guards: recovery replays (WebView process
    // death, Spotify device lost) re-invoke playCard for the active
    // card while isPlaying is still true, to rebuild a lost SDK
    // context. forceReplay must let them through, or a child is stuck
    // on silent playback with no way to recover.
    test('does not ignore a forced recovery replay', () {
      expect(
        shouldIgnoreRepeatPlay(
          cardId: 'a',
          activeCardId: 'a',
          isPlaying: true,
          forceReplay: true,
        ),
        isFalse,
      );
    });

    test('does not ignore a tap on a different card', () {
      expect(
        shouldIgnoreRepeatPlay(
          cardId: 'b',
          activeCardId: 'a',
          isPlaying: true,
          forceReplay: false,
        ),
        isFalse,
      );
    });

    test('does not ignore a tap while paused (re-tap resumes)', () {
      expect(
        shouldIgnoreRepeatPlay(
          cardId: 'a',
          activeCardId: 'a',
          isPlaying: false,
          forceReplay: false,
        ),
        isFalse,
      );
    });

    test('does not ignore when nothing is active', () {
      expect(
        shouldIgnoreRepeatPlay(
          cardId: 'a',
          activeCardId: null,
          isPlaying: false,
          forceReplay: false,
        ),
        isFalse,
      );
    });
  });

  group('interpolatePosition', () {
    test('returns anchor when not playing', () {
      expect(
        interpolatePosition(
          anchorMs: 5000,
          elapsedMs: 10000,
          durationMs: 300000,
          isPlaying: false,
        ),
        5000,
      );
    });

    test('returns anchor when duration is zero', () {
      expect(
        interpolatePosition(
          anchorMs: 5000,
          elapsedMs: 10000,
          durationMs: 0,
          isPlaying: true,
        ),
        5000,
      );
    });

    test('adds elapsed time when playing', () {
      expect(
        interpolatePosition(
          anchorMs: 10000,
          elapsedMs: 30000,
          durationMs: 300000,
          isPlaying: true,
        ),
        40000,
      );
    });

    test('clamps to duration (does not overshoot)', () {
      expect(
        interpolatePosition(
          anchorMs: 290000,
          elapsedMs: 30000,
          durationMs: 300000,
          isPlaying: true,
        ),
        300000,
      );
    });

    test('clamps to zero (does not undershoot)', () {
      expect(
        interpolatePosition(
          anchorMs: 0,
          elapsedMs: 0,
          durationMs: 300000,
          isPlaying: true,
        ),
        0,
      );
    });
  });

  group('shouldReplayAfterRecovery', () {
    // The bridge reports a recovery after a reload or an SDK drop. Only a
    // card that was playing gets restarted: a paused card stays paused,
    // and the next play recovers it through the device-lost replay.
    test('a Spotify card that was playing is replayed', () {
      expect(
        shouldReplayAfterRecovery(spotifyActive: true, wasPlaying: true),
        isTrue,
      );
    });

    test('a paused Spotify card stays paused', () {
      expect(
        shouldReplayAfterRecovery(spotifyActive: true, wasPlaying: false),
        isFalse,
      );
    });

    test('nothing is replayed while another backend plays', () {
      expect(
        shouldReplayAfterRecovery(spotifyActive: false, wasPlaying: true),
        isFalse,
      );
    });
  });
}
