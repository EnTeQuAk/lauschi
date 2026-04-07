import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/database/app_database.dart';
import 'package:lauschi/core/database/tile_item_repository.dart';
import 'package:lauschi/core/database/tile_repository.dart';

/// Unit tests for [TileRepository] CRUD + reorder.
///
/// Scope intentionally limited to the simple read/write paths. The
/// nesting / folder methods on this repository (`nestInto`, `unnest`,
/// `createFolderFromDrag`, the cycle-detection guards, the
/// auto-dissolve-empty-folder behavior) are covered end-to-end by
/// `integration_test/tile_nesting_test.dart`'s 9 patrolTests, which
/// exercise the real provider stream propagation alongside the DB
/// writes. Don't duplicate that coverage here — those flows depend on
/// stream observers reacting to writes, which is hard to fake at the
/// unit level. If you're considering adding a unit test for nesting,
/// check tile_nesting_test.dart first.
void main() {
  late AppDatabase db;
  late TileRepository groups;
  late TileItemRepository cards;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    groups = TileRepository(db);
    cards = TileItemRepository(db);
  });

  tearDown(() => db.close());

  test('insert and getAll returns the group', () async {
    // Context: empty DB before insert.
    expect(
      await groups.getAll(),
      isEmpty,
      reason: 'setup: fresh in-memory DB should have zero rows',
    );

    final id = await groups.insert(title: 'Yakari');

    // Context: insert returned a real id, not just a placeholder.
    expect(id, isNotEmpty, reason: 'insert should return a non-empty id');

    final all = await groups.getAll();
    expect(all, hasLength(1));
    expect(all.first.id, id);
    expect(all.first.title, 'Yakari');
  });

  test('sortOrder auto-increments', () async {
    final id1 = await groups.insert(title: 'First');
    final id2 = await groups.insert(title: 'Second');

    // Context: both inserts produced distinct rows. Without this
    // assert, a buggy insert that returned an existing id (or a
    // no-op) would silently turn this into a single-row test.
    expect(
      id1,
      isNot(equals(id2)),
      reason: 'inserts should produce unique ids',
    );
    final all = await groups.getAll();
    expect(
      all,
      hasLength(2),
      reason: 'setup: both inserts should produce 2 rows',
    );

    expect(all[0].sortOrder, 0);
    expect(all[1].sortOrder, 1);
  });

  test('update changes title and coverUrl', () async {
    final id = await groups.insert(title: 'Old Name');

    // Verify before state.
    final before = await groups.getById(id);
    expect(before, isNotNull, reason: 'setup: insert should be readable back');
    expect(before!.title, 'Old Name');
    expect(before.coverUrl, isNull);

    await groups.update(id: id, title: 'New Name', coverUrl: 'https://img.jpg');

    final after = await groups.getById(id);
    expect(after, isNotNull, reason: 'row should still exist after update');
    expect(after!.title, 'New Name');
    expect(after.coverUrl, 'https://img.jpg');
    // Other fields should be untouched.
    expect(after.id, id);
    expect(after.sortOrder, before.sortOrder);
    expect(after.contentType, before.contentType);
  });

  test('delete unassigns cards and removes group', () async {
    final groupId = await groups.insert(title: 'To Delete');
    final cardId = await cards.insert(
      title: 'Episode 1',
      providerUri: 'spotify:album:ep1',
      cardType: 'album',
    );
    await cards.assignToTile(itemId: cardId, tileId: groupId);

    // Context: setup put the group in the DB AND the card is
    // actually assigned to it. If `assignToTile` was a no-op, the
    // delete-unassigns assertion below would pass for the wrong
    // reason (`groupId` would already be null).
    expect(
      await groups.getAll(),
      hasLength(1),
      reason: 'setup: group should exist before delete',
    );
    final assigned = await cards.getById(cardId);
    expect(assigned, isNotNull, reason: 'setup: card should exist');
    expect(
      assigned!.groupId,
      groupId,
      reason: 'setup: card should be assigned to the group before delete',
    );

    await groups.delete(groupId);

    expect(await groups.getAll(), isEmpty);

    // Card still exists but is ungrouped. Data intact.
    final card = await cards.getById(cardId);
    expect(card, isNotNull, reason: 'card row should survive group delete');
    expect(card!.groupId, isNull, reason: 'card.groupId should be cleared');
    expect(card.title, 'Episode 1');
    expect(card.providerUri, 'spotify:album:ep1');
  });

  test('reorder updates sortOrder', () async {
    final id1 = await groups.insert(title: 'A');
    final id2 = await groups.insert(title: 'B');

    // Verify initial order.
    var all = await groups.getAll();
    expect(
      all,
      hasLength(2),
      reason: 'setup: both inserts should produce 2 rows',
    );
    expect(all[0].id, id1);
    expect(all[0].sortOrder, 0);
    expect(all[1].id, id2);
    expect(all[1].sortOrder, 1);

    await groups.reorder([id2, id1]);

    all = await groups.getAll();
    expect(all[0].id, id2);
    expect(all[0].sortOrder, 0);
    expect(all[1].id, id1);
    expect(all[1].sortOrder, 1);
  });

  test('watchCards returns cards in episode order', () async {
    final groupId = await groups.insert(title: 'Series');
    final id1 = await cards.insert(
      title: 'Episode 3',
      providerUri: 'spotify:album:ep3',
      cardType: 'album',
    );
    final id2 = await cards.insert(
      title: 'Episode 1',
      providerUri: 'spotify:album:ep1',
      cardType: 'album',
    );
    await cards.assignToTile(itemId: id1, tileId: groupId, episodeNumber: 3);
    await cards.assignToTile(itemId: id2, tileId: groupId, episodeNumber: 1);

    // Context: both cards landed AND are assigned to the group with
    // the right episode numbers. The "in episode order" assertion
    // below is meaningless if the cards aren't actually grouped.
    final assigned1 = await cards.getById(id1);
    final assigned2 = await cards.getById(id2);
    expect(assigned1?.groupId, groupId);
    expect(assigned1?.episodeNumber, 3);
    expect(assigned2?.groupId, groupId);
    expect(assigned2?.episodeNumber, 1);

    final grouped = await groups.watchItems(groupId).first;
    expect(grouped, hasLength(2));
    // The intentionally-inverted insert order above proves the
    // ordering comes from `episodeNumber`, not insertion order.
    expect(grouped[0].title, 'Episode 1');
    expect(grouped[1].title, 'Episode 3');
  });

  test('nextUnheard returns first unheard episode', () async {
    final groupId = await groups.insert(title: 'Series');
    final id1 = await cards.insert(
      title: 'Ep 1',
      providerUri: 'spotify:album:s1',
      cardType: 'album',
    );
    final id2 = await cards.insert(
      title: 'Ep 2',
      providerUri: 'spotify:album:s2',
      cardType: 'album',
    );
    await cards.assignToTile(itemId: id1, tileId: groupId, episodeNumber: 1);
    await cards.assignToTile(itemId: id2, tileId: groupId, episodeNumber: 2);

    // Both start unheard.
    var item1 = await cards.getById(id1);
    final item2 = await cards.getById(id2);
    expect(item1, isNotNull, reason: 'setup: card 1 should exist');
    expect(item2, isNotNull, reason: 'setup: card 2 should exist');
    expect(item1!.isHeard, isFalse);
    expect(item2!.isHeard, isFalse);

    await cards.markHeard(id1);

    // Ep 1 is now heard.
    item1 = await cards.getById(id1);
    expect(item1!.isHeard, isTrue);

    final next = await groups.nextUnheard(groupId);
    expect(next, isNotNull);
    expect(next!.id, id2);
    expect(next.title, 'Ep 2');
  });

  test('cardCount returns correct count', () async {
    final groupId = await groups.insert(title: 'Series');

    // Insert + assign two cards. Use plain await so the control
    // flow matches the rest of the file (and the future reader's
    // brain). The original `.then(...)` chaining was the odd one
    // out per the round-1 review.
    final cardId1 = await cards.insert(
      title: 'Ep 1',
      providerUri: 'spotify:album:c1',
      cardType: 'album',
    );
    await cards.assignToTile(itemId: cardId1, tileId: groupId);

    final cardId2 = await cards.insert(
      title: 'Ep 2',
      providerUri: 'spotify:album:c2',
      cardType: 'album',
    );
    await cards.assignToTile(itemId: cardId2, tileId: groupId);

    // Context: both assignments actually wrote `groupId` onto the
    // cards. If `assignToTile` was broken and left them ungrouped,
    // `itemCount` would return 0 and we'd get a confusing
    // `expected 2, actual 0` instead of "setup: both cards
    // should be assigned".
    final assigned1 = await cards.getById(cardId1);
    final assigned2 = await cards.getById(cardId2);
    expect(assigned1?.groupId, groupId, reason: 'setup: card 1 assigned');
    expect(assigned2?.groupId, groupId, reason: 'setup: card 2 assigned');

    final count = await groups.itemCount(groupId);
    expect(count, 2);
  });

  // assignToTile, removeFromTile, markHeard/markUnheard, watchUngrouped
  // are TileItemRepository methods — tests moved to
  // tile_item_repository_test.dart.
}
