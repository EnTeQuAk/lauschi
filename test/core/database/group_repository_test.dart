import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/database/app_database.dart';
import 'package:lauschi/core/database/card_repository.dart';
import 'package:lauschi/core/database/group_repository.dart';

void main() {
  late AppDatabase db;
  late GroupRepository groups;
  late CardRepository cards;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    groups = GroupRepository(db);
    cards = CardRepository(db);
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
    await cards.assignToGroup(cardId: cardId, groupId: groupId);

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
    await cards.assignToGroup(cardId: id1, groupId: groupId, episodeNumber: 3);
    await cards.assignToGroup(cardId: id2, groupId: groupId, episodeNumber: 1);

    final grouped = await groups.watchCards(groupId).first;
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
    await cards.assignToGroup(cardId: id1, groupId: groupId, episodeNumber: 1);
    await cards.assignToGroup(cardId: id2, groupId: groupId, episodeNumber: 2);
    await cards.markHeard(id1);

    final next = await groups.nextUnheard(groupId);
    expect(next, isNotNull);
    expect(next!.title, 'Ep 2');
  });

  test('cardCount returns correct count', () async {
    final groupId = await groups.insert(title: 'Series');
    await cards.insert(
      title: 'Ep 1',
      providerUri: 'spotify:album:c1',
      cardType: 'album',
    ).then((id) => cards.assignToGroup(cardId: id, groupId: groupId));
    await cards.insert(
      title: 'Ep 2',
      providerUri: 'spotify:album:c2',
      cardType: 'album',
    ).then((id) => cards.assignToGroup(cardId: id, groupId: groupId));

    final count = await groups.cardCount(groupId);
    expect(count, 2);
  });

  test('assignToGroup and removeFromGroup', () async {
    final groupId = await groups.insert(title: 'Group');
    final cardId = await cards.insert(
      title: 'Card',
      providerUri: 'spotify:album:x',
      cardType: 'album',
    );

    await cards.assignToGroup(
      cardId: cardId,
      groupId: groupId,
      episodeNumber: 5,
    );
    var card = await cards.getById(cardId);
    expect(card!.groupId, groupId);
    expect(card.episodeNumber, 5);

    await cards.removeFromGroup(cardId);
    card = await cards.getById(cardId);
    expect(card!.groupId, isNull);
    expect(card.episodeNumber, isNull);
  });

  test('markHeard and markUnheard toggle flag', () async {
    final cardId = await cards.insert(
      title: 'Story',
      providerUri: 'spotify:album:h1',
      cardType: 'album',
    );

    var card = await cards.getById(cardId);
    expect(card!.isHeard, false);

    await cards.markHeard(cardId);
    card = await cards.getById(cardId);
    expect(card!.isHeard, true);

    await cards.markUnheard(cardId);
    card = await cards.getById(cardId);
    expect(card!.isHeard, false);
  });

  test('watchUngrouped excludes grouped cards', () async {
    final groupId = await groups.insert(title: 'G');
    final id1 = await cards.insert(
      title: 'Grouped',
      providerUri: 'spotify:album:g1',
      cardType: 'album',
    );
    await cards.insert(
      title: 'Standalone',
      providerUri: 'spotify:album:s1',
      cardType: 'album',
    );
    await cards.assignToGroup(cardId: id1, groupId: groupId);

    final ungrouped = await cards.watchUngrouped().first;
    expect(ungrouped, hasLength(1));
    expect(ungrouped.first.title, 'Standalone');
  });
}
