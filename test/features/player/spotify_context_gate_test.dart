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
        isOwnTrack: null,
        isLastTrack: true,
      );
      final own = gate.accept(
        _state(track: '127-track1', positionMs: 0, durationMs: 202453),
        contextUri: _album127,
        isOwnTrack: null,
        isLastTrack: false,
      );

      expect(stale, isNull);
      expect(own, isNotNull);
      expect(own!.reachedEnd, isFalse);
    });

    test('a state without a context counts once the card started', () {
      final gate = SpotifyContextGate(_album127)..accept(
        _state(track: '127-track1', positionMs: 0, durationMs: 202453),
        contextUri: _album127,
        isOwnTrack: null,
        isLastTrack: false,
      );

      final state = gate.accept(
        _state(track: '127-track1', positionMs: 1000, durationMs: 202453),
        contextUri: null,
        isOwnTrack: null,
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
        isOwnTrack: null,
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
        isOwnTrack: null,
        isLastTrack: false,
      );

      expect(wrapped!.reachedEnd, isTrue);
    });

    test('autoplay moving to another album is the end', () {
      final gate = SpotifyContextGate(_album126)..accept(
        _state(track: 'track2', positionMs: 205000, durationMs: 206467),
        contextUri: _album126,
        isOwnTrack: null,
        isLastTrack: true,
      );

      final left = gate.accept(
        _state(track: 'recommended', positionMs: 0, durationMs: 150000),
        contextUri: 'spotify:album:something-else',
        isOwnTrack: null,
        isLastTrack: false,
      );

      expect(left!.reachedEnd, isTrue);
      expect(left.isPlaying, isFalse);
      expect(left.track?.uri, 'track2', reason: 'keeps showing this card');
    });

    test('a kid pausing on the last track is not the end', () {
      final gate = SpotifyContextGate(_album126)..accept(
        _state(track: 'track2', positionMs: 90000, durationMs: 206467),
        contextUri: _album126,
        isOwnTrack: null,
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
        isOwnTrack: null,
        isLastTrack: true,
      );

      expect(paused!.reachedEnd, isFalse);
    });

    test('moving from an earlier track to the next is not the end', () {
      final gate = SpotifyContextGate(_album126)..accept(
        _state(track: 'track1', positionMs: 200000, durationMs: 200506),
        contextUri: _album126,
        isOwnTrack: null,
        isLastTrack: false,
      );

      final next = gate.accept(
        _state(track: 'track2', positionMs: 0, durationMs: 206467),
        contextUri: _album126,
        isOwnTrack: null,
        isLastTrack: true,
      );

      expect(next!.reachedEnd, isFalse);
    });

    test("a kid's seek back to the start is not the end", () {
      final gate =
          SpotifyContextGate(_album126)
            ..accept(
              _state(track: 'track2', positionMs: 120000, durationMs: 206467),
              contextUri: _album126,
              isOwnTrack: null,
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
        isOwnTrack: null,
        isLastTrack: true,
      );

      expect(sought!.reachedEnd, isFalse);
    });

    test('another album playing mid-card is ignored, not the end', () {
      final gate = SpotifyContextGate(_album126)..accept(
        _state(track: 'track1', positionMs: 30000, durationMs: 200506),
        contextUri: _album126,
        isOwnTrack: null,
        isLastTrack: false,
      );

      final foreign = gate.accept(
        _state(track: 'other', positionMs: 0, durationMs: 1000),
        contextUri: 'spotify:album:other',
        isOwnTrack: null,
        isLastTrack: false,
      );

      expect(foreign, isNull);
    });
  });

  group('attributing a state to the card', () {
    test('no context and an unknown track before the card started is '
        'dropped (10-08 07:02:05, 6 ms after a tap)', () {
      final gate = SpotifyContextGate(_album127);

      final unattributed = gate.accept(
        _state(
          track: '126-track2',
          positionMs: 160532,
          durationMs: 165094,
          playing: false,
        ),
        contextUri: null,
        isOwnTrack: null,
        isLastTrack: true,
      );

      expect(unattributed, isNull);
    });

    test('a track of another card is dropped even with the right context', () {
      final gate = SpotifyContextGate(_album127);

      final stale = gate.accept(
        _state(
          track: '126-track2',
          positionMs: 160532,
          durationMs: 165094,
          playing: false,
        ),
        contextUri: _album127,
        isOwnTrack: false,
        isLastTrack: true,
      );

      expect(stale, isNull);
    });

    test("the card's own track opens the gate without a context", () {
      final gate = SpotifyContextGate(_album127);

      final own = gate.accept(
        _state(track: '127-track1', positionMs: 0, durationMs: 202453),
        contextUri: null,
        isOwnTrack: true,
        isLastTrack: false,
      );

      expect(own, isNotNull);
    });

    test('a foreign track after the last one is the end', () {
      final gate = SpotifyContextGate(_album126)..accept(
        _state(track: 'track2', positionMs: 205000, durationMs: 206467),
        contextUri: _album126,
        isOwnTrack: true,
        isLastTrack: true,
      );

      final left = gate.accept(
        _state(track: 'recommended', positionMs: 0, durationMs: 150000),
        contextUri: null,
        isOwnTrack: false,
        isLastTrack: false,
      );

      expect(left!.reachedEnd, isTrue);
    });
  });
}
