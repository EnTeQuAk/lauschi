import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/database/app_database.dart';
import 'package:lauschi/features/player/player_provider.dart';
import 'package:lauschi/features/player/player_state.dart';
import 'package:lauschi/features/tiles/card_indicator.dart';

TileItem _card({
  String id = 'card',
  bool heard = false,
  bool unavailable = false,
  int elapsedMs = 0,
}) => TileItem(
  id: id,
  title: 'Folge 1',
  cardType: 'album',
  provider: 'spotify',
  providerUri: 'spotify:album:$id',
  isHeard: heard,
  createdAt: DateTime(2026),
  totalTracks: 2,
  durationMs: elapsedMs > 0 ? 400000 : 0,
  lastTrackNumber: elapsedMs > 0 ? 1 : 0,
  lastPositionMs: elapsedMs,
  lastElapsedMs: elapsedMs,
  markedUnavailable: unavailable ? DateTime(2026) : null,
);

PlayerGridState _player({
  String? activeCardId,
  bool playing = false,
  bool loading = false,
  bool finished = false,
}) => (
  isPlaying: playing,
  isReady: true,
  isLoading: loading,
  isFinished: finished,
  track: activeCardId == null ? null : const TrackInfo(uri: 't', name: 'Track'),
  activeCardId: activeCardId,
);

void main() {
  group('status precedence', () {
    final cases = <(String, TileItem, PlayerGridState, CardStatus)>[
      ('nothing special', _card(), _player(), CardStatus.fresh),
      ('heard', _card(heard: true), _player(), CardStatus.heard),
      (
        'unavailable beats being in the player',
        _card(unavailable: true),
        _player(activeCardId: 'card', playing: true),
        CardStatus.unavailable,
      ),
      (
        'waiting for audio is starting, not paused',
        _card(),
        _player(activeCardId: 'card', loading: true),
        CardStatus.starting,
      ),
      (
        'playing',
        _card(),
        _player(activeCardId: 'card', playing: true),
        CardStatus.playing,
      ),
      (
        'playing a heard card shows playing',
        _card(heard: true),
        _player(activeCardId: 'card', playing: true),
        CardStatus.playing,
      ),
      (
        'paused before the end',
        _card(),
        _player(activeCardId: 'card'),
        CardStatus.paused,
      ),
      (
        'finished and stopped shows heard, not paused',
        _card(heard: true),
        _player(activeCardId: 'card', finished: true),
        CardStatus.heard,
      ),
      (
        'another card in the player leaves this one alone',
        _card(),
        _player(activeCardId: 'other', playing: true),
        CardStatus.fresh,
      ),
      (
        'an emptied player marks nothing',
        _card(),
        (
          isPlaying: false,
          isReady: true,
          isLoading: false,
          isFinished: false,
          track: null,
          activeCardId: 'card',
        ),
        CardStatus.fresh,
      ),
    ];
    for (final (name, card, player, status) in cases) {
      test(name, () {
        expect(cardIndicator(card, player: player).status, status);
      });
    }
  });

  test('marks the Weiter card', () {
    expect(
      cardIndicator(_card(), player: _player(), weiterId: 'card').isWeiter,
      isTrue,
    );
    expect(
      cardIndicator(_card(), player: _player(), weiterId: 'x').isWeiter,
      isFalse,
    );
  });

  test('an unavailable card never carries the Weiter badge', () {
    final indicator = cardIndicator(
      _card(unavailable: true),
      player: _player(),
      weiterId: 'card',
    );

    expect(indicator.isWeiter, isFalse);
  });

  test('progress shows for a resume point, not on heard cards', () {
    expect(
      cardIndicator(_card(elapsedMs: 100000), player: _player()).progress,
      0.25,
    );
    expect(
      cardIndicator(
        _card(heard: true, elapsedMs: 100000),
        player: _player(),
      ).progress,
      0,
    );
  });

  group('tileIndicator', () {
    test('counts heard items as progress', () {
      final indicator = tileIndicator((total: 4, heard: 1));

      expect(indicator.episodeCount, 4);
      expect(indicator.progress, 0.25);
      expect(indicator.isUnavailable, isFalse);
    });

    test('a tile whose items are all unavailable is unavailable', () {
      expect(tileIndicator((total: 0, heard: 0)).isUnavailable, isTrue);
    });

    test('a tile without items is empty, not unavailable', () {
      final indicator = tileIndicator(null);

      expect(indicator.isUnavailable, isFalse);
      expect(indicator.progress, 0);
    });
  });
}
