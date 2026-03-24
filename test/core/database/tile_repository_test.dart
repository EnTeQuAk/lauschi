import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/database/app_database.dart';
import 'package:lauschi/core/database/tile_item_repository.dart';
import 'package:lauschi/core/database/tile_repository.dart';

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
    final id = await groups.insert(title: 'Yakari');

    final all = await groups.getAll();
    expect(all, hasLength(1));
    expect(all.first.id, id);
    expect(all.first.title, 'Yakari');
  });

  test('sortOrder auto-increments', () async {
    await groups.insert(title: 'First');
    await groups.insert(title: 'Second');

    final all = await groups.getAll();
    expect(all[0].sortOrder, 0);
    expect(all[1].sortOrder, 1);
  });

  test('update changes title and coverUrl', () async {
    final id = await groups.insert(title: 'Old Name');

    // Verify before state.
    final before = await groups.getById(id);
    expect(before!.title, 'Old Name');
    expect(before.coverUrl, isNull);

    await groups.update(id: id, title: 'New Name', coverUrl: 'https://img.jpg');

    final after = await groups.getById(id);
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

    // Verify before state.
    final assigned = await cards.getById(cardId);
    expect(assigned!.groupId, groupId);
    expect(await groups.getAll(), hasLength(1));

    await groups.delete(groupId);

    expect(await groups.getAll(), isEmpty);

    // Card still exists but is ungrouped. Data intact.
    final card = await cards.getById(cardId);
    expect(card, isNotNull);
    expect(card!.groupId, isNull);
    expect(card.title, 'Episode 1');
    expect(card.providerUri, 'spotify:album:ep1');
  });

  test('reorder updates sortOrder', () async {
    final id1 = await groups.insert(title: 'A');
    final id2 = await groups.insert(title: 'B');

    // Verify initial order.
    var all = await groups.getAll();
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

    final grouped = await groups.watchItems(groupId).first;
    expect(grouped, hasLength(2));
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
    var item2 = await cards.getById(id2);
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
    await cards
        .insert(
          title: 'Ep 1',
          providerUri: 'spotify:album:c1',
          cardType: 'album',
        )
        .then((id) => cards.assignToTile(itemId: id, tileId: groupId));
    await cards
        .insert(
          title: 'Ep 2',
          providerUri: 'spotify:album:c2',
          cardType: 'album',
        )
        .then((id) => cards.assignToTile(itemId: id, tileId: groupId));

    final count = await groups.itemCount(groupId);
    expect(count, 2);
  });

  // assignToTile, removeFromTile, markHeard/markUnheard, watchUngrouped
  // are TileItemRepository methods — tests moved to
  // tile_item_repository_test.dart.
}
