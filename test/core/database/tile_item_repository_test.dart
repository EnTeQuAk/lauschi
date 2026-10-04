import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/database/app_database.dart';
import 'package:lauschi/core/database/tile_item_repository.dart';
import 'package:lauschi/core/database/tile_repository.dart';

/// Unit tests for [TileItemRepository] CRUD + playback-position
/// persistence + assignment to tiles + expiration lifecycle.
///
/// All tests use the shared `db` from setUp. Earlier versions of this
/// file created standalone `db2` instances for the assignToTile and
/// watchUngrouped tests; the round-1 review flagged that as
/// inconsistent and unexplained, so they now share the same in-memory
/// DB. setUp creates a fresh DB per test so isolation is preserved
/// without per-test instances.
void main() {
  late AppDatabase db;
  late TileRepository tiles;
  late TileItemRepository repo;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    tiles = TileRepository(db);
    repo = TileItemRepository(db);
  });

  tearDown(() => db.close());

  test('insert and getAll returns the card', () async {
    // Context: empty DB before insert. Without this, an `insert` that
    // silently no-ops AND a previously-leaked row from a missing
    // tearDown would both pass `hasLength(1)` for the wrong reason.
    expect(
      await repo.getAll(),
      isEmpty,
      reason: 'setup: fresh in-memory DB should have zero rows',
    );

    final id = await repo.insert(
      title: 'Test Album',
      providerUri: 'spotify:album:abc123',
      cardType: 'album',
    );

    // Context: insert returned a non-empty id (not just a stub).
    expect(id, isNotEmpty, reason: 'insert should return a non-empty id');

    final cards = await repo.getAll();
    expect(cards, hasLength(1));
    expect(cards.first.id, id);
    expect(cards.first.title, 'Test Album');
    expect(cards.first.providerUri, 'spotify:album:abc123');
  });

  test('insertIfAbsent deduplicates by providerUri', () async {
    final id1 = await repo.insertIfAbsent(
      title: 'Album A',
      providerUri: 'spotify:album:abc123',
      cardType: 'album',
    );

    // Context: the first insert actually landed. Without this, a
    // broken `insertIfAbsent` that always returned a fresh id but
    // never wrote could pass the `id2 == id1` assertion below for
    // the wrong reason (both calls returning the same generated
    // id but neither persisting).
    expect(
      await repo.getAll(),
      hasLength(1),
      reason: 'setup: first insert should persist 1 row',
    );

    final id2 = await repo.insertIfAbsent(
      title: 'Album A Again',
      providerUri: 'spotify:album:abc123',
      cardType: 'album',
    );

    expect(id2, id1, reason: 'second insert should return the existing id');
    final cards = await repo.getAll();
    expect(cards, hasLength(1), reason: 'duplicate URI did not add a row');
  });

  test(
    'insert derives the provider column from the providerUri prefix',
    () async {
      // A mislabeled provider column routes playback to the wrong backend
      // (an Apple Music card handed to the Spotify player fails silently
      // for the kid) and makes catalog reconciliation skip the row.
      await repo.insert(
        title: 'Bibi und Tina Folge 1',
        providerUri: 'apple_music:album:1686062068',
        cardType: 'album',
      );
      await repo.insert(
        title: 'Checker Tobi',
        providerUri: 'ard:item:urn123',
        cardType: 'episode',
      );

      final am = await repo.getByProviderUri('apple_music:album:1686062068');
      final ard = await repo.getByProviderUri('ard:item:urn123');
      expect(am!.provider, 'apple_music');
      expect(ard!.provider, 'ard_audiothek');
    },
  );

  test(
    'insertIfAbsent stores an Apple Music album with its own provider',
    () async {
      final id = await repo.insertIfAbsent(
        title: 'Die drei ??? Folge 100',
        providerUri: 'apple_music:album:987654',
        cardType: 'album',
      );

      final card = await repo.getByProviderUri('apple_music:album:987654');
      expect(card!.id, id);
      expect(card.provider, 'apple_music');
    },
  );

  test('concurrent insertIfAbsent calls create only one row', () async {
    // A double-tap on the add button fires two calls before either
    // commits. Without atomicity both selects see an empty table and
    // both insert, leaving duplicate rows that later crash lookups.
    final ids = await Future.wait([
      repo.insertIfAbsent(
        title: 'Album',
        providerUri: 'spotify:album:race1',
        cardType: 'album',
      ),
      repo.insertIfAbsent(
        title: 'Album',
        providerUri: 'spotify:album:race1',
        cardType: 'album',
      ),
    ]);

    expect(ids[0], ids[1], reason: 'both calls should resolve to one card');
    expect(await repo.getAll(), hasLength(1));
  });

  test('duplicate providerUri rows do not break lookups', () async {
    // Installs that raced the add flow before insertIfAbsent became
    // transactional can hold duplicate rows. Lookups must degrade to
    // picking one row, not throw StateError forever.
    for (var i = 0; i < 2; i++) {
      await _insertRawCard(
        db,
        id: 'dup-row-$i',
        providerUri: 'spotify:album:dup1',
      );
    }

    final card = await repo.getByProviderUri('spotify:album:dup1');
    expect(card, isNotNull);

    final id = await repo.insertIfAbsent(
      title: 'Album',
      providerUri: 'spotify:album:dup1',
      cardType: 'album',
    );
    expect(id, isNotEmpty);
    expect(
      await repo.getAll(),
      hasLength(2),
      reason: 'insertIfAbsent must reuse an existing row, not add a third',
    );
  });

  test('insert rejects a providerUri with an unknown prefix', () async {
    await expectLater(
      repo.insert(title: 'x', providerUri: 'bogus:album:1', cardType: 'album'),
      throwsArgumentError,
    );
    expect(
      await repo.getAll(),
      isEmpty,
      reason: 'a rejected insert must not leave a row behind',
    );
  });

  test('sortOrder is null on insert (auto-sort by episodeNumber)', () async {
    final id1 = await repo.insert(
      title: 'First',
      providerUri: 'spotify:album:1',
      cardType: 'album',
    );
    final id2 = await repo.insert(
      title: 'Second',
      providerUri: 'spotify:album:2',
      cardType: 'album',
    );

    expect(id1, isNot(equals(id2)), reason: 'inserts produce unique ids');

    final cards = await repo.getAll();
    expect(cards, hasLength(2), reason: 'setup: both inserts persist');

    expect(cards[0].sortOrder, isNull);
    expect(cards[1].sortOrder, isNull);
  });

  test('delete removes the card', () async {
    final id = await repo.insert(
      title: 'To Delete',
      providerUri: 'spotify:album:del',
      cardType: 'album',
    );

    // Context: the row actually exists before delete. Without this,
    // a `delete` that's a no-op AND an `insert` that silently fails
    // would both pass `expect(cards, isEmpty)`.
    expect(
      await repo.getAll(),
      hasLength(1),
      reason: 'setup: row should exist before delete',
    );

    await repo.delete(id);

    final cards = await repo.getAll();
    expect(cards, isEmpty);
  });

  test('reorder updates sortOrder for all cards', () async {
    final id1 = await repo.insert(
      title: 'A',
      providerUri: 'spotify:album:a',
      cardType: 'album',
    );
    final id2 = await repo.insert(
      title: 'B',
      providerUri: 'spotify:album:b',
      cardType: 'album',
    );

    // Context: initial order is A then B. The reorder behavior
    // below is only meaningful if we know the starting order.
    var cards = await repo.getAll();
    expect(cards, hasLength(2));
    expect(cards[0].id, id1, reason: 'setup: first insert is at index 0');
    expect(cards[1].id, id2, reason: 'setup: second insert is at index 1');

    // Reverse order
    await repo.reorder([id2, id1]);

    cards = await repo.getAll();
    expect(cards[0].id, id2);
    expect(cards[1].id, id1);
  });

  test('spotifyArtistIds stored as comma-separated string', () async {
    const ids = ['5BOhng5bYwJNOR8ckMWpUg', '2ndArtistId'];

    // Context: input list has 2 distinct ids. The CSV-encoding
    // assertion below is only meaningful if we control the input.
    expect(ids, hasLength(2));
    expect(ids[0], isNot(equals(ids[1])));

    final id = await repo.insert(
      title: 'Folge 38: Eile mit Weile',
      providerUri: 'spotify:album:yakari38',
      cardType: 'album',
      spotifyArtistIds: ids,
    );

    final card = await repo.getById(id);
    expect(card, isNotNull);
    expect(card!.spotifyArtistIds, '5BOhng5bYwJNOR8ckMWpUg,2ndArtistId');
  });

  test('spotifyArtistIds null when not provided', () async {
    final id = await repo.insert(
      title: 'Some Album',
      providerUri: 'spotify:album:noartist',
      cardType: 'album',
    );

    final card = await repo.getById(id);
    expect(card, isNotNull);
    expect(card!.spotifyArtistIds, isNull);
  });

  test('assignToTile and removeFromTile', () async {
    final groupId = await tiles.insert(title: 'Group');
    final cardId = await repo.insert(
      title: 'Card',
      providerUri: 'spotify:album:x',
      cardType: 'album',
    );

    // Context: card is unassigned (groupId null) and the tile we
    // want to assign it to actually exists. The round-trip below
    // (assign, observe, remove, observe) is only meaningful if both
    // sides of the FK exist before we link them.
    final initial = await repo.getById(cardId);
    expect(initial, isNotNull, reason: 'setup: card exists');
    expect(initial!.groupId, isNull, reason: 'setup: card unassigned');
    expect(
      await tiles.getById(groupId),
      isNotNull,
      reason: 'setup: target tile exists',
    );

    await repo.assignToTile(itemId: cardId, tileId: groupId, episodeNumber: 5);
    var card = await repo.getById(cardId);
    expect(card, isNotNull);
    expect(card!.groupId, groupId);
    expect(card.episodeNumber, 5);

    await repo.removeFromTile(cardId);
    card = await repo.getById(cardId);
    expect(card, isNotNull);
    expect(card!.groupId, isNull);
    expect(card.episodeNumber, isNull);
  });

  test(
    'assignToTile without episodeNumber keeps the existing number',
    () async {
      // A curated episode carries its number (e.g. TKKG Folge 140). When
      // the parent moves it to another tile via the group picker or a
      // drag — neither of which passes an episode number — the number must
      // survive. Writing Value(null) here erases it and drops the item to
      // the bottom of the tile via the sortLast sentinel; for ARD items,
      // which reconcile never repairs, the number is gone for good.
      final tileA = await tiles.insert(title: 'Tile A');
      final tileB = await tiles.insert(title: 'Tile B');
      final cardId = await repo.insert(
        title: 'TKKG Folge 140',
        providerUri: 'ard:item:tkkg140',
        cardType: 'episode',
      );

      await repo.assignToTile(
        itemId: cardId,
        tileId: tileA,
        episodeNumber: 140,
      );
      var card = await repo.getById(cardId);
      expect(
        card!.episodeNumber,
        140,
        reason: 'setup: number assigned in tile A',
      );
      expect(card.groupId, tileA, reason: 'setup: card is in tile A');

      // Reassign to a different tile without passing an episode number.
      await repo.assignToTile(itemId: cardId, tileId: tileB);
      card = await repo.getById(cardId);
      expect(card!.groupId, tileB, reason: 'card moved to tile B');
      expect(
        card.episodeNumber,
        140,
        reason: 'omitting episodeNumber must not erase the stored number',
      );
    },
  );

  test('watchUngrouped excludes grouped items', () async {
    final groupId = await tiles.insert(title: 'G');
    final id1 = await repo.insert(
      title: 'Grouped',
      providerUri: 'spotify:album:g1',
      cardType: 'album',
    );
    await repo.insert(
      title: 'Standalone',
      providerUri: 'spotify:album:s1',
      cardType: 'album',
    );
    await repo.assignToTile(itemId: id1, tileId: groupId);

    // Context: the DB has 2 items total — one grouped, one not.
    // Without this assertion, the `hasLength(1)` on the ungrouped
    // stream below could pass if the second insert silently failed.
    expect(
      await repo.getAll(),
      hasLength(2),
      reason: 'setup: both items should be in the DB',
    );
    final groupedItem = await repo.getById(id1);
    expect(
      groupedItem?.groupId,
      groupId,
      reason: 'setup: first item should be assigned to the group',
    );

    final ungrouped = await repo.watchUngrouped().first;
    expect(ungrouped, hasLength(1));
    expect(ungrouped.first.title, 'Standalone');
  });

  test(
    'insertIfAbsent does not overwrite existing card on duplicate URI',
    () async {
      final firstId = await repo.insertIfAbsent(
        title: 'Original Title',
        providerUri: 'spotify:album:dup',
        cardType: 'album',
        spotifyArtistIds: ['artist1'],
      );

      // Context: the first insert actually wrote the row with the
      // values we expect. Without this assert, a buggy insertIfAbsent
      // that swallowed the first insert would let the test pass on
      // the second call's behavior alone.
      final original = await repo.getById(firstId);
      expect(original, isNotNull, reason: 'setup: first insert persisted');
      expect(original!.title, 'Original Title');
      expect(original.spotifyArtistIds, 'artist1');

      final secondId = await repo.insertIfAbsent(
        title: 'New Title',
        providerUri: 'spotify:album:dup',
        cardType: 'album',
        spotifyArtistIds: ['artist2'],
      );

      // Behavior: the duplicate insertIfAbsent returned the same id
      // and DID NOT overwrite the row.
      expect(
        secondId,
        firstId,
        reason: 'duplicate URI returns the existing id',
      );

      final cards = await repo.getAll();
      expect(cards, hasLength(1), reason: 'no extra row was created');
      expect(cards.first.title, 'Original Title');
      expect(cards.first.spotifyArtistIds, 'artist1');
    },
  );

  group('updateMeta', () {
    test('writes customTitle and coverUrl', () async {
      final id = await repo.insert(
        title: 'Original',
        providerUri: 'spotify:album:meta',
        cardType: 'album',
        coverUrl: 'https://img/old.jpg',
      );

      // Context: insert wrote what we expect — otherwise the "changed"
      // assertions below could pass for the wrong reason.
      final before = await repo.getById(id);
      expect(before, isNotNull, reason: 'setup: row exists');
      expect(before!.customTitle, isNull);
      expect(before.coverUrl, 'https://img/old.jpg');

      await repo.updateMeta(
        id: id,
        customTitle: 'Renamed',
        coverUrl: 'https://img/new.jpg',
      );

      final after = await repo.getById(id);
      expect(after!.customTitle, 'Renamed');
      expect(after.coverUrl, 'https://img/new.jpg');
      // Untouched fields stay put.
      expect(after.title, 'Original');
      expect(after.providerUri, 'spotify:album:meta');
    });

    test('clearCustomTitle nulls the override', () async {
      final id = await repo.insert(
        title: 'Original',
        providerUri: 'spotify:album:clr',
        cardType: 'album',
      );
      await repo.updateMeta(id: id, customTitle: 'Custom');

      final renamed = await repo.getById(id);
      expect(
        renamed?.customTitle,
        'Custom',
        reason: 'setup: override must be set before testing clear',
      );

      await repo.updateMeta(id: id, clearCustomTitle: true);
      final after = await repo.getById(id);
      expect(after!.customTitle, isNull);
      expect(after.title, 'Original', reason: 'original title untouched');
    });

    test('omitted parameters do not clobber existing values', () async {
      final id = await repo.insert(
        title: 'Untouched',
        providerUri: 'spotify:album:absent',
        cardType: 'album',
        coverUrl: 'https://img/keep.jpg',
      );
      await repo.updateMeta(id: id, customTitle: 'Renamed');

      final after = await repo.getById(id);
      expect(after!.customTitle, 'Renamed');
      expect(
        after.coverUrl,
        'https://img/keep.jpg',
        reason: 'omitting coverUrl must leave the value alone',
      );
    });
  });

  // ─── Content expiration ───────────────────────────────────────────

  // isItemUnavailable only checks markedUnavailable (runtime flag).
  // availableUntil is informational; ARD's endDate is unreliable.
  group('isItemUnavailable', () {
    test('not expired when neither field set', () async {
      final id = await repo.insert(
        title: 'Normal Track',
        providerUri: 'spotify:track:abc',
        cardType: 'album',
      );
      final card = (await repo.getAll()).firstWhere((c) => c.id == id);

      // Context: this card has neither expiration field set. The
      // test name says it all, but assert it explicitly so a future
      // change to insert defaults can't accidentally make this pass
      // for the wrong reason.
      expect(card.markedUnavailable, isNull);
      expect(card.availableUntil, isNull);

      expect(isItemUnavailable(card), isFalse);
    });

    test('not expired when only availableUntil is in the past', () async {
      // availableUntil alone does NOT make an item expired.
      // ARD CDN keeps serving audio well past endDate.
      final pastDate = DateTime.now().subtract(const Duration(days: 1));
      final id = await repo.insertArdEpisode(
        title: 'Past endDate',
        providerUri: 'ard:past',
        audioUrl: 'https://example.com/past.mp3',
        availableUntil: pastDate,
      );
      final card = (await repo.getAll()).firstWhere((c) => c.id == id);

      // Context: availableUntil parsed from JSON correctly AND is
      // in the past AND markedUnavailable is null. This is the
      // exact precondition under test — drop any of those and the
      // test name lies.
      expect(card.availableUntil, isNotNull, reason: 'setup: parsed date');
      expect(
        card.availableUntil!.isBefore(DateTime.now()),
        isTrue,
        reason: 'setup: date is in the past',
      );
      expect(
        card.markedUnavailable,
        isNull,
        reason: 'setup: not flagged unavailable',
      );

      expect(
        isItemUnavailable(card),
        isFalse,
        reason:
            'past availableUntil alone is not expiration; ARD CDN '
            'keeps serving these well past endDate',
      );
    });

    test('expired when markedUnavailable is set', () async {
      final id = await repo.insert(
        title: 'Removed',
        providerUri: 'spotify:track:removed',
        cardType: 'album',
      );

      // Context: row exists with markedUnavailable null BEFORE the
      // mark. Otherwise this test could pass if `insert` accidentally
      // set markedUnavailable for new rows.
      final beforeMark = await repo.getById(id);
      expect(beforeMark, isNotNull);
      expect(beforeMark!.markedUnavailable, isNull);

      await repo.markUnavailable(id);

      final card = (await repo.getAll()).firstWhere((c) => c.id == id);
      expect(card.markedUnavailable, isNotNull, reason: 'mark wrote a value');
      expect(isItemUnavailable(card), isTrue);
    });
  });

  group('markUnavailable and clearUnavailable', () {
    test('markUnavailable sets the flag', () async {
      final id = await repo.insert(
        title: 'Mark Test',
        providerUri: 'spotify:track:mark',
        cardType: 'album',
      );

      // Context: flag starts null. Without this, a broken `insert`
      // that pre-sets `markedUnavailable` would make the test pass
      // even if `markUnavailable` was a no-op.
      final before = await repo.getById(id);
      expect(
        before?.markedUnavailable,
        isNull,
        reason: 'setup: not yet marked',
      );

      await repo.markUnavailable(id);
      final card = (await repo.getAll()).firstWhere((c) => c.id == id);
      expect(card.markedUnavailable, isNotNull);
    });

    test('clearUnavailable removes the flag', () async {
      final id = await repo.insert(
        title: 'Clear Test',
        providerUri: 'spotify:track:clear',
        cardType: 'album',
      );

      await repo.markUnavailable(id);

      // Context: marking actually set the flag. Without this assert,
      // `clearUnavailable` succeeding on an already-null field would
      // pass for the wrong reason.
      final marked = await repo.getById(id);
      expect(
        marked?.markedUnavailable,
        isNotNull,
        reason: 'setup: mark must succeed before testing clear',
      );

      await repo.clearUnavailable(id);
      final card = (await repo.getAll()).firstWhere((c) => c.id == id);
      expect(card.markedUnavailable, isNull);
      expect(isItemUnavailable(card), isFalse);
    });
  });

  group('getUnavailable', () {
    test('returns only items with markedUnavailable set', () async {
      await repo.insert(
        title: 'Available',
        providerUri: 'ard:ok',
        cardType: 'episode',
      );
      final removedId = await repo.insert(
        title: 'Removed',
        providerUri: 'spotify:track:gone',
        cardType: 'album',
      );
      await repo.markUnavailable(removedId);

      // Context: 2 rows total, exactly 1 marked. The "returns only"
      // assertion is meaningless without proving there are 2 rows
      // in the first place.
      expect(
        await repo.getAll(),
        hasLength(2),
        reason: 'setup: 1 available + 1 removed = 2 rows total',
      );

      final unavailable = await repo.getUnavailable();
      expect(unavailable, hasLength(1));
      expect(unavailable.first.id, removedId);
    });

    test('olderThan filters by mark age', () async {
      final id = await repo.insert(
        title: 'Old Mark',
        providerUri: 'spotify:track:old',
        cardType: 'album',
      );
      final beforeMark = DateTime.now();
      await repo.markUnavailable(id);

      // Context: the mark is FRESH (just now). The "older than 7 days"
      // filter is only meaningful if we know the mark isn't actually
      // 7+ days old. The 5-second window covers Drift IO latency.
      final marked = await repo.getById(id);
      expect(marked?.markedUnavailable, isNotNull);
      expect(
        marked!.markedUnavailable!.isAfter(
          beforeMark.subtract(const Duration(seconds: 5)),
        ),
        isTrue,
        reason: 'setup: mark is recent',
      );

      // Marked just now, so "older than 7 days" should return nothing.
      final recent = await repo.getUnavailable(
        olderThan: const Duration(days: 7),
      );
      expect(recent, isEmpty);

      // No olderThan filter returns everything.
      final all = await repo.getUnavailable();
      expect(all, hasLength(1));
    });
  });
}

/// Insert a card row directly, bypassing the repository's dedup and
/// URI validation. Simulates rows written by older app versions.
Future<void> _insertRawCard(
  AppDatabase db, {
  required String id,
  required String providerUri,
}) {
  return db
      .into(db.cards)
      .insert(
        CardsCompanion.insert(
          id: id,
          title: 'Raw row',
          cardType: 'album',
          providerUri: providerUri,
          provider: const Value('spotify'),
        ),
      );
}
