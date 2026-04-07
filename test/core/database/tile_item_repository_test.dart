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

  test('sortOrder auto-increments', () async {
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

    // Context: both inserts produced distinct rows. A buggy insert
    // returning the same id would silently turn this into a 1-row test.
    expect(id1, isNot(equals(id2)), reason: 'inserts produce unique ids');

    final cards = await repo.getAll();
    expect(cards, hasLength(2), reason: 'setup: both inserts persist');

    expect(cards[0].sortOrder, 0);
    expect(cards[1].sortOrder, 1);
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

  test('savePosition and getByProviderUri persist playback state', () async {
    final id = await repo.insert(
      title: 'Audiobook',
      providerUri: 'spotify:album:book1',
      cardType: 'album',
    );

    // Verify initial state is blank — context: this proves
    // savePosition CHANGED something rather than the card always
    // having had those values.
    var card = await repo.getByProviderUri('spotify:album:book1');
    expect(card, isNotNull, reason: 'setup: getByProviderUri should find row');
    expect(card!.lastTrackUri, isNull);
    expect(card.lastPositionMs, 0);
    expect(card.lastPlayedAt, isNull);

    final beforeSave = DateTime.now().subtract(const Duration(seconds: 1));
    await repo.savePosition(
      itemId: id,
      trackUri: 'spotify:track:ch5',
      positionMs: 45000,
    );

    card = await repo.getByProviderUri('spotify:album:book1');
    expect(card, isNotNull);
    expect(card!.lastTrackUri, 'spotify:track:ch5');
    expect(card.lastPositionMs, 45000);
    // Tighten the lastPlayedAt assert: it must be a real "now" value,
    // not just non-null. A buggy savePosition that wrote a stale
    // timestamp (or `DateTime(2000)`) would still pass `isNotNull`.
    expect(card.lastPlayedAt, isNotNull);
    expect(
      card.lastPlayedAt!.isAfter(beforeSave),
      isTrue,
      reason: 'lastPlayedAt should be the current time, not a stale value',
    );

    // Verify other fields untouched.
    expect(card.title, 'Audiobook');
    expect(card.providerUri, 'spotify:album:book1');
  });

  test('resetPlaybackPosition clears saved position', () async {
    final id = await repo.insert(
      title: 'Audiobook',
      providerUri: 'spotify:album:book2',
      cardType: 'album',
    );

    // Set a saved position.
    await repo.savePosition(
      itemId: id,
      trackUri: 'spotify:track:ch7',
      positionMs: 90000,
      trackNumber: 7,
    );

    // Sanity: position is saved AND we wrote what we expected.
    // The whole `reset` test is meaningless if there's nothing to
    // reset because savePosition didn't actually save.
    var card = await repo.getById(id);
    expect(card, isNotNull, reason: 'setup: card should exist');
    expect(
      card!.lastTrackUri,
      'spotify:track:ch7',
      reason: 'setup: savePosition should have written lastTrackUri',
    );
    expect(card.lastTrackNumber, 7);
    expect(card.lastPositionMs, 90000);

    // Reset and verify position fields are cleared.
    await repo.resetPlaybackPosition(id);

    card = await repo.getById(id);
    expect(card, isNotNull, reason: 'item should still exist after reset');
    expect(card!.lastTrackUri, isNull, reason: 'lastTrackUri cleared');
    expect(card.lastTrackNumber, 0, reason: 'lastTrackNumber cleared');
    expect(card.lastPositionMs, 0, reason: 'lastPositionMs cleared');
    // Untouched fields stay intact.
    expect(card.title, 'Audiobook', reason: 'title preserved');
    expect(card.providerUri, 'spotify:album:book2', reason: 'URI preserved');
  });

  test('resetPlaybackPosition is a no-op for unknown item id', () async {
    // Should not throw, should not affect existing items.
    await repo.insert(
      title: 'Existing',
      providerUri: 'spotify:album:exists',
      cardType: 'album',
    );

    // Context: there is exactly one row in the DB before the no-op.
    // We're proving that `resetPlaybackPosition('does-not-exist')`
    // doesn't accidentally delete or rewrite the existing row.
    expect(
      await repo.getAll(),
      hasLength(1),
      reason: 'setup: 1 existing row that should be untouched',
    );

    await repo.resetPlaybackPosition('does-not-exist');

    final cards = await repo.getAll();
    expect(cards, hasLength(1), reason: 'no-op preserved the existing row');
    expect(cards.first.title, 'Existing');
  });

  test('lastPlayed returns most recently played card', () async {
    final oldId = await repo.insert(
      title: 'Old',
      providerUri: 'spotify:album:old',
      cardType: 'album',
    );
    final newId = await repo.insert(
      title: 'New',
      providerUri: 'spotify:album:new',
      cardType: 'album',
    );

    // Context: BEFORE saving any position, the "Old" card has
    // `lastPlayedAt == null`. This is the load-bearing context
    // assert: without it, the test could pass even if `lastPlayed()`
    // returned the most-recently-INSERTED card instead of the
    // most-recently-PLAYED one (the round-1 review caught this gap).
    final oldBeforeSave = await repo.getById(oldId);
    expect(oldBeforeSave, isNotNull);
    expect(
      oldBeforeSave!.lastPlayedAt,
      isNull,
      reason:
          'setup: "Old" card has no saved play time, '
          'so a correct lastPlayed() must NOT pick it',
    );

    await repo.savePosition(
      itemId: newId,
      trackUri: 'spotify:track:t1',
      positionMs: 1000,
    );

    final last = await repo.lastPlayed();
    expect(last, isNotNull);
    expect(last!.title, 'New');
    // Belt and suspenders: explicitly verify it's not the old one.
    expect(last.id, newId, reason: 'lastPlayed should match the saved id');
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

    await repo.assignToTile(
      itemId: cardId,
      tileId: groupId,
      episodeNumber: 5,
    );
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

  test('markHeard and markUnheard toggle flag', () async {
    final id = await repo.insert(
      title: 'Story',
      providerUri: 'spotify:album:h1',
      cardType: 'album',
    );

    // Context: items default to unheard. The toggle test below
    // depends on this being the starting state.
    var card = await repo.getById(id);
    expect(card, isNotNull);
    expect(
      card!.isHeard,
      isFalse,
      reason: 'setup: new items default to unheard',
    );

    await repo.markHeard(id);
    card = await repo.getById(id);
    expect(card!.isHeard, isTrue);

    await repo.markUnheard(id);
    card = await repo.getById(id);
    expect(card!.isHeard, isFalse);
  });

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

  // ─── Content expiration ───────────────────────────────────────────

  // isItemExpired only checks markedUnavailable (runtime flag).
  // availableUntil is informational; ARD's endDate is unreliable.
  group('isItemExpired', () {
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

      expect(isItemExpired(card), isFalse);
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
        isItemExpired(card),
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
      expect(isItemExpired(card), isTrue);
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
      expect(isItemExpired(card), isFalse);
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
