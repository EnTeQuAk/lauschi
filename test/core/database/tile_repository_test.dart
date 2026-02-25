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
    await groups.update(id: id, title: 'New Name', coverUrl: 'https://img.jpg');

    final group = await groups.getById(id);
    expect(group!.title, 'New Name');
    expect(group.coverUrl, 'https://img.jpg');
  });

  test('delete unassigns cards and removes group', () async {
    final groupId = await groups.insert(title: 'To Delete');
    final cardId = await cards.insert(
      title: 'Episode 1',
      providerUri: 'spotify:album:ep1',
      cardType: 'album',
    );
    await cards.assignToTile(itemId: cardId, tileId: groupId);

    await groups.delete(groupId);

    final allGroups = await groups.getAll();
    expect(allGroups, isEmpty);

    // Card still exists but is ungrouped
    final card = await cards.getById(cardId);
    expect(card, isNotNull);
    expect(card!.groupId, isNull);
  });

  test('reorder updates sortOrder', () async {
    final id1 = await groups.insert(title: 'A');
    final id2 = await groups.insert(title: 'B');

    await groups.reorder([id2, id1]);

    final all = await groups.getAll();
    expect(all[0].id, id2);
    expect(all[1].id, id1);
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
    await cards.markHeard(id1);

    final next = await groups.nextUnheard(groupId);
    expect(next, isNotNull);
    expect(next!.title, 'Ep 2');
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
