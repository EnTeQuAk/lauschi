import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/database/app_database.dart';
import 'package:lauschi/core/database/tile_item_repository.dart';
import 'package:lauschi/core/database/tile_repository.dart';
import 'package:lauschi/core/database/weiter.dart';

TileItem _item(String id, {bool unavailable = false, bool heard = false}) {
  return TileItem(
    id: id,
    title: id,
    cardType: 'album',
    provider: 'spotify',
    providerUri: 'spotify:album:$id',
    isHeard: heard,
    createdAt: DateTime(2026),
    totalTracks: 1,
    durationMs: 0,
    lastTrackNumber: 0,
    lastPositionMs: 0,
    lastElapsedMs: 0,
    markedUnavailable: unavailable ? DateTime(2026) : null,
  );
}

List<String?> _ids(Iterable<TileItem?> items) => [for (final i in items) i?.id];

void main() {
  group('nextAfter', () {
    final items = [_item('a'), _item('b'), _item('c')];

    test('is the following item', () {
      expect(nextAfter(items, 'a')?.id, 'b');
    });

    test('ignores heard state', () {
      final withHeard = [_item('a'), _item('b', heard: true), _item('c')];

      expect(nextAfter(withHeard, 'a')?.id, 'b');
    });

    test('wraps to the start after the last item', () {
      expect(nextAfter(items, 'c')?.id, 'a');
    });

    test('skips unavailable items, also across the wrap', () {
      final gappy = [
        _item('a', unavailable: true),
        _item('b'),
        _item('c', unavailable: true),
      ];

      expect(nextAfter(gappy, 'b')?.id, 'b', reason: 'only b is playable');
      expect(nextAfter(gappy, 'a')?.id, 'b');
    });

    test('an id not in the list starts at the first playable item', () {
      expect(nextAfter(items, 'gone')?.id, 'a');
    });

    test('is null when nothing is playable', () {
      expect(nextAfter([_item('a', unavailable: true)], 'a'), isNull);
      expect(nextAfter(const [], 'a'), isNull);
    });
  });

  group('weiterFor', () {
    final items = [_item('a'), _item('b'), _item('c')];

    test('is the stored item', () {
      expect(weiterFor(items, 'b')?.id, 'b');
    });

    test('a tile nobody listened to starts at the first item', () {
      expect(weiterFor(items, null)?.id, 'a');
    });

    test('a stored item that left the tile starts at the first item', () {
      expect(weiterFor(items, 'gone')?.id, 'a');
    });

    test('an unavailable stored item hands over to the next playable', () {
      final gappy = [_item('a'), _item('b', unavailable: true), _item('c')];

      expect(weiterFor(gappy, 'b')?.id, 'c');
    });

    test('skips unavailable items at the start', () {
      final gappy = [_item('a', unavailable: true), _item('b')];

      expect(weiterFor(gappy, null)?.id, 'b');
    });
  });

  group('cardOrder', () {
    late AppDatabase db;
    late TileRepository tiles;
    late TileItemRepository items;
    late String tileId;

    setUp(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      tiles = TileRepository(db);
      items = TileItemRepository(db);
      tileId = await tiles.insert(title: 'Series');
    });

    tearDown(() => db.close());

    Future<String> add(String title, {int? episode, int? sortOrder}) async {
      final id = await items.insert(
        title: title,
        providerUri: 'spotify:album:$title',
        cardType: 'album',
      );
      await items.assignToTile(
        itemId: id,
        tileId: tileId,
        episodeNumber: episode,
      );
      if (sortOrder != null) {
        await (db.update(db.cards)..where(
          (t) => t.id.equals(id),
        )).write(CardsCompanion(sortOrder: Value(sortOrder)));
      }
      return id;
    }

    Future<List<String>> order() async => [
      for (final item in await tiles.watchItems(tileId).first) item.title,
    ];

    test('sorts by episode number, specials last', () async {
      await add('special');
      await add('ep2', episode: 2);
      await add('ep1', episode: 1);

      expect(await order(), ['ep1', 'ep2', 'special']);
    });

    test('a manual order wins over episode numbers', () async {
      await add('ep1', episode: 1, sortOrder: 1);
      await add('ep2', episode: 2, sortOrder: 0);

      expect(await order(), ['ep2', 'ep1']);
    });

    test('items added after a manual sort follow the sorted run', () async {
      // Manual position 1 and episode number 1 are different scales. They
      // used to share one sort key, so a later-added episode slotted into
      // the middle of a hand-sorted run.
      await add('first', episode: 50, sortOrder: 0);
      await add('second', episode: 10, sortOrder: 1);
      await add('third', episode: 30, sortOrder: 2);
      await add('late-ep1', episode: 1);
      await add('late-ep2', episode: 2);

      expect(await order(), [
        'first',
        'second',
        'third',
        'late-ep1',
        'late-ep2',
      ]);
    });

    test('nextAfter follows the same order', () async {
      final first = await add('first', episode: 50, sortOrder: 0);
      await add('late-ep1', episode: 1);

      final ordered = await tiles.watchItems(tileId).first;

      expect(_ids([nextAfter(ordered, first)]), [
        ordered.firstWhere((i) => i.title == 'late-ep1').id,
      ]);
    });
  });
}
