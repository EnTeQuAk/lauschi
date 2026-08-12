import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/database/app_database.dart';
import 'package:lauschi/core/database/tile_item_repository.dart';
import 'package:lauschi/features/player/player_error.dart';
import 'package:lauschi/features/player/player_provider.dart';
import 'package:lauschi/features/player/player_state.dart';

/// Real notifier with a seeded state: card-1 is loaded and playing.
/// playCard itself is NOT overridden, so the test exercises the real
/// entry path.
class _PlayingCard1 extends PlayerNotifier {
  @override
  PlaybackState build() => const PlaybackState(
    activeCardId: 'card-1',
    isPlaying: true,
    isReady: true,
    track: TrackInfo(uri: 'ard:item:card-1', name: 'Folge 7'),
  );
}

/// Insert a card row directly with a fixed id and the unavailable flag.
Future<void> _insertUnavailable(AppDatabase db, String id) {
  return db
      .into(db.cards)
      .insert(
        CardsCompanion.insert(
          id: id,
          title: 'Folge 7',
          cardType: 'episode',
          providerUri: 'ard:item:$id',
          provider: const Value('ard_audiothek'),
          markedUnavailable: Value(DateTime(2026)),
        ),
      );
}

void main() {
  test('playCard on the already-playing card is a no-op', () async {
    // A kid tapping the card with the playing badge (or re-presenting
    // an NFC figure) must not tear down the backend: that cuts the
    // audio and resumes from the last saved position, audibly jumping
    // the story backwards. In this bare container any attempt to
    // actually start playback would throw on missing services, so
    // completing without error proves the early return.
    final container = ProviderContainer(
      overrides: [playerProvider.overrideWith(_PlayingCard1.new)],
    );
    addTearDown(container.dispose);
    final before = container.read(playerProvider);

    await container.read(playerProvider.notifier).playCard('card-1');

    expect(
      container.read(playerProvider),
      same(before),
      reason: 'state must be untouched, no teardown or reload',
    );
  });

  test('forceReplay proceeds past the guard even while playing', () async {
    // Recovery replays (WebView process death, Spotify device lost)
    // re-invoke playCard for the active card while isPlaying is still
    // true. If the guard blocked them the child would be stuck on
    // silent playback. card-1 is marked unavailable, so a replay that
    // gets past the guard reaches the markedUnavailable check and sets
    // contentUnavailable — a state change the no-op path never makes,
    // and one that stops before any backend is touched.
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _insertUnavailable(db, 'card-1');

    final container = ProviderContainer(
      overrides: [
        playerProvider.overrideWith(_PlayingCard1.new),
        tileItemRepositoryProvider.overrideWith(
          (ref) => TileItemRepository(db),
        ),
      ],
    );
    addTearDown(container.dispose);

    await container
        .read(playerProvider.notifier)
        .playCard('card-1', forceReplay: true);

    expect(
      container.read(playerProvider).error,
      PlayerError.contentUnavailable,
      reason: 'forced replay must run playCard, not hit the re-tap guard',
    );
  });

  test('a normal re-tap never reaches the card lookup', () async {
    // Same setup as the forceReplay test, but without the flag: the
    // guard must short-circuit before the repo is ever consulted, so
    // the unavailable card is never seen and no error is set.
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _insertUnavailable(db, 'card-1');

    final container = ProviderContainer(
      overrides: [
        playerProvider.overrideWith(_PlayingCard1.new),
        tileItemRepositoryProvider.overrideWith(
          (ref) => TileItemRepository(db),
        ),
      ],
    );
    addTearDown(container.dispose);

    await container.read(playerProvider.notifier).playCard('card-1');

    expect(container.read(playerProvider).error, isNull);
  });
}
