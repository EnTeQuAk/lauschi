import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/features/player/player_state.dart';
import 'package:lauschi/features/player/spotify_player.dart';

const _album126 = 'spotify:album:folge126';
const _album127 = 'spotify:album:folge127';

PlaybackState _state({
  required String track,
  required int positionMs,
  required int durationMs,
  bool playing = true,
}) => PlaybackState(
  isReady: true,
  isPlaying: playing,
  positionMs: positionMs,
  durationMs: durationMs,
  track: TrackInfo(uri: track, name: track),
);

void main() {
  group('a card accepts only its own context', () {
    test("the previous card's last state is dropped (10-04 17:00:30)", () {
      // The kid tapped 127 in the last second of 126. The bridge's pause
      // for 126 arrived after 127's play command and, accepted, marked
      // 127 heard before it played a second.
      final gate = SpotifyContextGate(_album127);

      final stale = gate.accept(
        _state(
          track: '126-track2',
          positionMs: 179661,
          durationMs: 180040,
          playing: false,
        ),
        contextUri: _album126,
        isLastTrack: true,
      );
      final own = gate.accept(
        _state(track: '127-track1', positionMs: 0, durationMs: 202453),
        contextUri: _album127,
        isLastTrack: false,
      );

      expect(stale, isNull);
      expect(own, isNotNull);
      expect(own!.isFinished, isFalse);
    });

    test('a state without a context counts as its own', () {
      final gate = SpotifyContextGate(_album127);

      final state = gate.accept(
        _state(track: 't', positionMs: 0, durationMs: 1000),
        contextUri: null,
        isLastTrack: false,
      );

      expect(state, isNotNull);
    });
  });

  group('the end of the album', () {
    test('wrapping to the start, paused, is the end (10-04 16:47)', () {
      final gate = SpotifyContextGate(_album126)..accept(
        _state(track: 'track2', positionMs: 202301, durationMs: 206467),
        contextUri: _album126,
        isLastTrack: true,
      );

      final wrapped = gate.accept(
        _state(
          track: 'track1',
          positionMs: 0,
          durationMs: 200506,
          playing: false,
        ),
        contextUri: _album126,
        isLastTrack: false,
      );

      expect(wrapped!.isFinished, isTrue);
    });

    test('autoplay moving to another album is the end', () {
      final gate = SpotifyContextGate(_album126)..accept(
        _state(track: 'track2', positionMs: 205000, durationMs: 206467),
        contextUri: _album126,
        isLastTrack: true,
      );

      final left = gate.accept(
        _state(track: 'recommended', positionMs: 0, durationMs: 150000),
        contextUri: 'spotify:album:something-else',
        isLastTrack: false,
      );

      expect(left!.isFinished, isTrue);
      expect(left.isPlaying, isFalse);
      expect(left.track?.uri, 'track2', reason: 'keeps showing this card');
    });

    test('a kid pausing on the last track is not the end', () {
      final gate = SpotifyContextGate(_album126)..accept(
        _state(track: 'track2', positionMs: 90000, durationMs: 206467),
        contextUri: _album126,
        isLastTrack: true,
      );

      final paused = gate.accept(
        _state(
          track: 'track2',
          positionMs: 90100,
          durationMs: 206467,
          playing: false,
        ),
        contextUri: _album126,
        isLastTrack: true,
      );

      expect(paused!.isFinished, isFalse);
    });

    test('moving from an earlier track to the next is not the end', () {
      final gate = SpotifyContextGate(_album126)..accept(
        _state(track: 'track1', positionMs: 200000, durationMs: 200506),
        contextUri: _album126,
        isLastTrack: false,
      );

      final next = gate.accept(
        _state(track: 'track2', positionMs: 0, durationMs: 206467),
        contextUri: _album126,
        isLastTrack: true,
      );

      expect(next!.isFinished, isFalse);
    });

    test("a kid's seek back to the start is not the end", () {
      final gate =
          SpotifyContextGate(_album126)
            ..accept(
              _state(track: 'track2', positionMs: 120000, durationMs: 206467),
              contextUri: _album126,
              isLastTrack: true,
            )
            ..expectJump();

      final sought = gate.accept(
        _state(
          track: 'track2',
          positionMs: 0,
          durationMs: 206467,
          playing: false,
        ),
        contextUri: _album126,
        isLastTrack: true,
      );

      expect(sought!.isFinished, isFalse);
    });

    test('another album playing mid-card is ignored, not the end', () {
      final gate = SpotifyContextGate(_album126)..accept(
        _state(track: 'track1', positionMs: 30000, durationMs: 200506),
        contextUri: _album126,
        isLastTrack: false,
      );

      final foreign = gate.accept(
        _state(track: 'other', positionMs: 0, durationMs: 1000),
        contextUri: 'spotify:album:other',
        isLastTrack: false,
      );

      expect(foreign, isNull);
    });
  });
}
