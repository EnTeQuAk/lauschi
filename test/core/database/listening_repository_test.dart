import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/database/app_database.dart';
import 'package:lauschi/core/database/listening_repository.dart';
import 'package:lauschi/core/database/tile_item_repository.dart';
import 'package:lauschi/core/database/tile_repository.dart';

void main() {
  late AppDatabase db;
  late TileRepository tiles;
  late TileItemRepository items;
  late ListeningRepository listening;
  late String tileId;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    tiles = TileRepository(db);
    items = TileItemRepository(db);
    listening = ListeningRepository(db);
    tileId = await tiles.insert(title: 'Ninjago');
  });

  tearDown(() => db.close());

  Future<String> addEpisode(int number, {String? inTile}) async {
    final id = await items.insert(
      title: 'Folge $number',
      providerUri: 'spotify:album:ep$number',
      cardType: 'album',
      totalTracks: 2,
    );
    await items.assignToTile(
      itemId: id,
      tileId: inTile ?? tileId,
      episodeNumber: number,
    );
    return id;
  }

  Future<String?> weiterOf(String id) async =>
      (await tiles.getById(id))!.weiterItemId;

  Future<void> saveResumePoint(String id, {int positionMs = 60000}) =>
      listening.saveResumePoint(
        itemId: id,
        trackUri: 'spotify:track:$id',
        trackNumber: 2,
        positionMs: positionMs,
        elapsedMs: 200000 + positionMs,
        durationMs: 400000,
      );

  group('startItem', () {
    test('makes the item the Weiter item and clears the others', () async {
      final ep1 = await addEpisode(1);
      final ep2 = await addEpisode(2);
      await saveResumePoint(ep1);

      await listening.startItem(ep2);

      expect(await weiterOf(tileId), ep2);
      final ep1Row = await items.getById(ep1);
      expect(ep1Row!.lastPositionMs, 0, reason: 'one resume point per tile');
      expect(ep1Row.lastElapsedMs, 0);
      expect(ep1Row.lastPlayedAt, isNull);
    });

    test('keeps the started item own resume point', () async {
      final ep1 = await addEpisode(1);
      await saveResumePoint(ep1, positionMs: 42000);

      await listening.startItem(ep1);

      expect((await items.getById(ep1))!.lastPositionMs, 42000);
    });

    test('an ungrouped item touches no tile', () async {
      final loose = await items.insert(
        title: 'Loose',
        providerUri: 'spotify:album:loose',
        cardType: 'album',
      );

      await listening.startItem(loose);

      expect(await weiterOf(tileId), isNull);
    });
  });

  group('saveResumePoint', () {
    test('stores the position and the whole-item duration', () async {
      final ep1 = await addEpisode(1);

      await saveResumePoint(ep1);

      final row = await items.getById(ep1);
      expect(row!.lastTrackUri, 'spotify:track:$ep1');
      expect(row.lastTrackNumber, 2);
      expect(row.lastPositionMs, 60000);
      expect(row.lastElapsedMs, 260000);
      expect(row.durationMs, 400000);
      expect(row.lastPlayedAt, isNotNull);
    });

    test('an unknown duration keeps the stored one', () async {
      final ep1 = await addEpisode(1);
      await saveResumePoint(ep1);

      await listening.saveResumePoint(
        itemId: ep1,
        trackUri: 'spotify:track:x',
        trackNumber: 1,
        positionMs: 1000,
        elapsedMs: 1000,
        durationMs: 0,
      );

      expect((await items.getById(ep1))!.durationMs, 400000);
    });
  });

  group('finishItem', () {
    test('marks heard, forgets the resume point, moves Weiter on', () async {
      final ep1 = await addEpisode(1);
      final ep2 = await addEpisode(2);
      await listening.startItem(ep1);
      await saveResumePoint(ep1);

      await listening.finishItem(ep1);

      final row = await items.getById(ep1);
      expect(row!.isHeard, isTrue);
      expect(row.lastPositionMs, 0, reason: 'a replay starts at the top');
      expect(row.lastTrackUri, isNull);
      expect(await weiterOf(tileId), ep2);
    });

    test('moves to the next episode even when it was heard before', () async {
      // Kids hear series two and three times: after an episode always
      // comes the next one, not the next one they haven't heard.
      final ep1 = await addEpisode(1);
      final ep2 = await addEpisode(2);
      await addEpisode(3);
      await listening.finishItem(ep2);

      await listening.finishItem(ep1);

      expect(await weiterOf(tileId), ep2);
    });

    test('a replayed early episode leads to the one after it', () async {
      // The Weiter item is not "the frontier of heard episodes": finishing
      // Folge 125 while 171 to 178 were heard leads to 126, not 179.
      final ep125 = await addEpisode(125);
      final ep126 = await addEpisode(126);
      final ep178 = await addEpisode(178);
      await addEpisode(179);
      await listening.finishItem(ep178);

      await listening.finishItem(ep125);

      expect(await weiterOf(tileId), ep126);
    });

    test('wraps to the first episode after the last one', () async {
      final ep1 = await addEpisode(1);
      final ep2 = await addEpisode(2);

      await listening.finishItem(ep2);

      expect(await weiterOf(tileId), ep1);
    });

    test('skips unavailable episodes', () async {
      final ep1 = await addEpisode(1);
      final ep2 = await addEpisode(2);
      final ep3 = await addEpisode(3);
      await items.markUnavailable(ep2);

      await listening.finishItem(ep1);

      expect(await weiterOf(tileId), ep3);
    });

    test('a standalone item only forgets its own resume point', () async {
      final loose = await items.insert(
        title: 'Loose',
        providerUri: 'spotify:album:loose',
        cardType: 'album',
      );
      await saveResumePoint(loose);

      await listening.finishItem(loose);

      final row = await items.getById(loose);
      expect(row!.isHeard, isTrue);
      expect(row.lastPositionMs, 0);
    });

    test('the tile stream sees the finish as one change', () async {
      // Heard flag, resume point and Weiter land in one transaction, so a
      // watching grid never renders the half-done state between them.
      final ep1 = await addEpisode(1);
      await addEpisode(2);
      final emissions = <List<TileItem>>[];
      final sub = tiles.watchItems(tileId).listen(emissions.add);
      await pumpEventQueue();
      emissions.clear();

      await listening.finishItem(ep1);
      await pumpEventQueue();

      expect(emissions, hasLength(1));
      await sub.cancel();
    });
  });

  group('handing over Weiter when the item leaves', () {
    late String ep1;
    late String ep2;

    setUp(() async {
      ep1 = await addEpisode(1);
      ep2 = await addEpisode(2);
      await listening.startItem(ep1);
    });

    test('removing it from the tile moves Weiter to the next', () async {
      await items.removeFromTile(ep1);

      expect(await weiterOf(tileId), ep2);
    });

    test('deleting it moves Weiter to the next', () async {
      await items.delete(ep1);

      expect(await weiterOf(tileId), ep2);
    });

    test('moving it to another tile moves Weiter to the next', () async {
      final otherTile = await tiles.insert(title: 'Other');

      await items.assignToTile(itemId: ep1, tileId: otherTile);

      expect(await weiterOf(tileId), ep2);
      expect(await weiterOf(otherTile), isNull);
    });

    test('the last item leaving clears Weiter', () async {
      await items.delete(ep2);
      await items.delete(ep1);

      expect(await weiterOf(tileId), isNull);
    });

    test('another item leaving keeps Weiter', () async {
      await items.delete(ep2);

      expect(await weiterOf(tileId), ep1);
    });
  });

  test('resetResumePoint forgets where playback stood', () async {
    final ep1 = await addEpisode(1);
    await saveResumePoint(ep1);

    await listening.resetResumePoint(ep1);

    final row = await items.getById(ep1);
    expect(row!.lastPositionMs, 0);
    expect(row.lastPlayedAt, isNull);
  });

  test('Weiter writes go through the groups table only', () async {
    // Guards the schema: the stored Weiter is a column on the tile, so a
    // parent's manual reorder (which rewrites sort orders) leaves it be.
    final ep1 = await addEpisode(1);
    final ep2 = await addEpisode(2);
    await listening.startItem(ep2);

    await items.reorder([ep2, ep1]);

    expect(await weiterOf(tileId), ep2);
    expect(
      await (db.select(db.groups)
        ..where((t) => t.weiterItemId.equals(ep2))).get(),
      hasLength(1),
    );
  });
}
