import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/ard/ard_api.dart';
import 'package:lauschi/core/database/app_database.dart';
import 'package:lauschi/core/database/data_migrations.dart';
import 'package:lauschi/core/database/tile_item_repository.dart';
import 'package:lauschi/core/database/tile_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

typedef _StoryOrder = ({String? storyId, bool latestFirst});

/// Answers story order lookups from a fixed table and records each call.
class _FakeArdApi extends ArdApi {
  _FakeArdApi(this.order);

  final Map<String, _StoryOrder> order;
  final List<List<String>> calls = [];

  /// The publish date backfill runs in the same pass: nothing to date.
  @override
  Future<Map<String, DateTime>> getPublishDates(List<String> itemIds) async =>
      {};

  @override
  Future<Map<String, _StoryOrder>> getStoryOrder(List<String> itemIds) async {
    calls.add(itemIds);
    return {
      for (final id in itemIds)
        if (order[id] case final facts?) id: facts,
    };
  }
}

/// Tiles of ARD shows that run on play their stories latest first since
/// schema 16. The tiles and episodes a parent added before learn it from
/// ARD once.
void main() {
  late AppDatabase db;
  late TileRepository tiles;
  late TileItemRepository items;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase.forTesting(NativeDatabase.memory());
    tiles = TileRepository(db);
    items = TileItemRepository(db);
  });

  tearDown(() => db.close());

  Future<String> episode(String ardId, String tileId) => items.insertArdEpisode(
    title: 'Folge $ardId',
    providerUri: 'ard:item:$ardId',
    audioUrl: 'https://cdn/$ardId.mp3',
    tileId: tileId,
  );

  Future<void> migrate(_FakeArdApi api) => runDataMigrations(
    DataMigrationContext(items: items, tiles: tiles, ard: api),
  );

  test('a tile of a show that runs on plays latest first', () async {
    final betthupferl = await tiles.insert(title: 'Betthupferl');
    final glitzerGang = await tiles.insert(title: 'Die Glitzer-Gang');
    final luise1 = await episode('1', betthupferl);
    final luise2 = await episode('2', betthupferl);
    final beppo = await episode('3', betthupferl);
    final folge1 = await episode('4', glitzerGang);

    await migrate(
      _FakeArdApi({
        '1': (storyId: 'luise', latestFirst: true),
        '2': (storyId: 'luise', latestFirst: true),
        '3': (storyId: null, latestFirst: true),
        '4': (storyId: 'glitzer', latestFirst: false),
      }),
    );

    expect((await tiles.getById(betthupferl))!.latestFirst, isTrue);
    expect((await tiles.getById(glitzerGang))!.latestFirst, isFalse);
    expect((await items.getById(luise1))!.storyId, 'luise');
    expect((await items.getById(luise2))!.storyId, 'luise');
    expect((await items.getById(beppo))!.storyId, isNull);
    expect((await items.getById(folge1))!.storyId, 'glitzer');
  });

  test('a tile mixing in a show that ends keeps its order', () async {
    final mixed = await tiles.insert(title: 'Gute Nacht');
    await episode('1', mixed);
    await episode('2', mixed);

    await migrate(
      _FakeArdApi({
        '1': (storyId: null, latestFirst: true),
        '2': (storyId: null, latestFirst: false),
      }),
    );

    expect((await tiles.getById(mixed))!.latestFirst, isFalse);
  });

  test('episodes ARD no longer lists do not decide a tile', () async {
    final betthupferl = await tiles.insert(title: 'Betthupferl');
    await episode('1', betthupferl);
    await episode('2', betthupferl);

    await migrate(_FakeArdApi({'1': (storyId: null, latestFirst: true)}));

    expect((await tiles.getById(betthupferl))!.latestFirst, isTrue);
  });

  test('asks ARD in batches of 100', () async {
    final tile = await tiles.insert(title: 'Betthupferl');
    for (var i = 0; i < 150; i++) {
      await episode('$i', tile);
    }
    final api = _FakeArdApi({});

    await migrate(api);

    expect(api.calls.map((c) => c.length), [100, 50]);
  });
}
