import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/database/app_database.dart';
import 'package:lauschi/core/database/tile_item_repository.dart';
import 'package:lauschi/core/database/tile_repository.dart';

/// Restore (undo) fidelity for the destructive tile/item actions.
///
/// Every destructive op returns a [TileSnapshot]; [TileRepository.restore]
/// must put the exact rows back, deleted ones re-inserted and moved ones
/// reset, including episode order, heard state, and saved position.
void main() {
  late AppDatabase db;
  late TileRepository tileRepo;
  late TileItemRepository itemRepo;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    tileRepo = TileRepository(db);
    itemRepo = TileItemRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> insertTile(
    String id, {
    String title = 'Tile',
    String? parentId,
    int sortOrder = 0,
  }) {
    return db
        .into(db.groups)
        .insert(
          GroupsCompanion.insert(
            id: id,
            title: title,
            parentTileId: Value(parentId),
            sortOrder: Value(sortOrder),
          ),
        );
  }

  Future<void> insertCard(
    String id, {
    required String? tileId,
    String title = 'Episode',
    int? episodeNumber,
    int? sortOrder,
    bool isHeard = false,
    int lastPositionMs = 0,
  }) {
    return db
        .into(db.cards)
        .insert(
          CardsCompanion.insert(
            id: id,
            title: title,
            cardType: 'episode',
            providerUri: 'ard:$id',
            groupId: Value(tileId),
            episodeNumber: Value(episodeNumber),
            sortOrder: Value(sortOrder),
            isHeard: Value(isHeard),
            lastPositionMs: Value(lastPositionMs),
          ),
        );
  }

  test(
    'deleting a tile removes its episodes; restore brings them all back',
    () async {
      await insertTile('t1', title: 'TKKG');
      await insertCard(
        'c1',
        tileId: 't1',
        episodeNumber: 1,
        sortOrder: 0,
        isHeard: true,
        lastPositionMs: 42000,
      );
      await insertCard('c2', tileId: 't1', episodeNumber: 2, sortOrder: 1);

      final snapshot = await tileRepo.delete('t1');

      expect(await tileRepo.getById('t1'), isNull);
      expect(await itemRepo.getById('c1'), isNull);
      expect(await itemRepo.getById('c2'), isNull);

      await tileRepo.restore(snapshot);

      expect((await tileRepo.getById('t1'))?.title, 'TKKG');
      final c1 = await itemRepo.getById('c1');
      expect(c1, isNotNull);
      expect(c1!.groupId, 't1');
      expect(c1.episodeNumber, 1);
      expect(c1.sortOrder, 0);
      expect(
        c1.isHeard,
        isTrue,
        reason: 'heard state must survive the round-trip',
      );
      expect(c1.lastPositionMs, 42000, reason: 'saved position must survive');
      expect((await itemRepo.getById('c2'))?.groupId, 't1');
    },
  );

  test(
    'deleting a nested subtree; restore brings back parent, child, cards',
    () async {
      await insertTile('parent', title: 'Ordner');
      await insertTile('child', title: 'TKKG', parentId: 'parent');
      await insertCard('c1', tileId: 'child', episodeNumber: 1);

      final snapshot = await tileRepo.delete('parent');

      expect(await tileRepo.getById('parent'), isNull);
      expect(await tileRepo.getById('child'), isNull);
      expect(await itemRepo.getById('c1'), isNull);

      await tileRepo.restore(snapshot);

      expect(await tileRepo.getById('parent'), isNotNull);
      expect((await tileRepo.getById('child'))?.parentTileId, 'parent');
      expect((await itemRepo.getById('c1'))?.groupId, 'child');
    },
  );

  test(
    'deleting a single item; restore brings it back with its state',
    () async {
      await insertCard('c1', tileId: null, isHeard: true, lastPositionMs: 5000);

      final snapshot = await itemRepo.delete('c1');
      expect(await itemRepo.getById('c1'), isNull);

      await tileRepo.restore(snapshot);
      final restored = await itemRepo.getById('c1');
      expect(restored?.isHeard, isTrue);
      expect(restored?.lastPositionMs, 5000);
    },
  );

  test('deleteByTile clears the episodes; restore brings them back', () async {
    await insertTile('t1');
    await insertCard('c1', tileId: 't1', sortOrder: 0);
    await insertCard('c2', tileId: 't1', sortOrder: 1);

    final snapshot = await itemRepo.deleteByTile('t1');
    expect(await itemRepo.getById('c1'), isNull);
    expect(await itemRepo.getById('c2'), isNull);

    await tileRepo.restore(snapshot);
    expect((await itemRepo.getById('c1'))?.groupId, 't1');
    expect((await itemRepo.getById('c2'))?.groupId, 't1');
  });

  test('removeFromTile ungroups an item; restore re-groups it', () async {
    await insertTile('t1');
    await insertCard('c1', tileId: 't1', episodeNumber: 3, sortOrder: 2);

    final snapshot = await itemRepo.removeFromTile('c1');
    final ungrouped = await itemRepo.getById('c1');
    expect(ungrouped?.groupId, isNull);
    expect(ungrouped?.episodeNumber, isNull);

    await tileRepo.restore(snapshot);
    final regrouped = await itemRepo.getById('c1');
    expect(regrouped?.groupId, 't1');
    expect(regrouped?.episodeNumber, 3);
    expect(regrouped?.sortOrder, 2);
  });

  test('unnest a tile moves it out; restore re-nests it', () async {
    await insertTile('parent');
    await insertTile('child', parentId: 'parent', sortOrder: 5);

    final snapshot = await tileRepo.unnest('child');
    expect((await tileRepo.getById('child'))?.parentTileId, isNull);

    await tileRepo.restore(snapshot);
    final child = await tileRepo.getById('child');
    expect(child?.parentTileId, 'parent');
    expect(child?.sortOrder, 5);
  });

  test('restore of an empty snapshot is a no-op', () async {
    await tileRepo.restore(const TileSnapshot());
    expect(await db.select(db.groups).get(), isEmpty);
    expect(await db.select(db.cards).get(), isEmpty);
  });
}
