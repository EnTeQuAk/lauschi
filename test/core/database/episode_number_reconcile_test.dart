import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/catalog/catalog_service.dart';
import 'package:lauschi/core/database/app_database.dart';
import 'package:lauschi/core/database/tile_item_repository.dart';
import 'package:lauschi/core/providers/provider_type.dart';

/// Reconciling stored episode numbers against the catalog.
///
/// Episode numbers are facts about an album, derived once in the curation
/// pipeline (see docs/catalog-episode-numbers.md). A tile item holding a
/// different number than the catalog is stale by definition, so the app
/// adopts the catalog's value whenever both are available.
///
/// This is what repairs installs that added albums before the app stopped
/// re-deriving numbers itself, and it keeps repairing them as the catalog
/// is corrected: today's Hui Buh re-labelling moved all six of its
/// episodes, and existing tiles would otherwise keep the wrong numbers
/// forever.
///
/// Album ids below are real, taken from series.yaml, so these tests fail
/// loudly if those entries change or disappear.
void main() {
  late AppDatabase db;
  late TileItemRepository repo;
  late CatalogService catalog;

  // der_kleine_hui_buh, curated episodes 1 and 2.
  const huiBuhEp1 = 'spotify:album:2UmBBDJFEUnyOJ4JHb10uE';
  const huiBuhEp2 = 'spotify:album:7bw5jglJ7loXOhSv4Hu2Xe';
  // bibi_und_tina_kinofilm, a film with no episode number.
  const filmNoEpisode = 'spotify:album:0vFYfQ9UHDvz4zTCKOpgcj';

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    catalog = await CatalogService.load();
  });

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = TileItemRepository(db);
  });

  tearDown(() => db.close());

  Future<TileItem> only() async => (await repo.getAll()).single;

  test('fills a missing episode number from the catalog', () async {
    await repo.insert(
      title: 'Hui Buh whatever the user saw',
      providerUri: huiBuhEp1,
      cardType: 'album',
    );
    expect((await only()).episodeNumber, isNull, reason: 'setup');

    final changed = await repo.reconcileEpisodeNumbers(catalog);

    expect(changed, 1);
    expect((await only()).episodeNumber, 1);
  });

  test('corrects a wrong episode number', () async {
    // The Hui Buh case: every episode of that series was off by one, so
    // installs carry numbers that no longer match the catalog.
    final id = await repo.insert(
      title: 'Hui Buh',
      providerUri: huiBuhEp2,
      cardType: 'album',
    );
    await (db.update(db.cards)..where((t) => t.id.equals(id))).write(
      const CardsCompanion(episodeNumber: Value(6)),
    );

    final changed = await repo.reconcileEpisodeNumbers(catalog);

    expect(changed, 1);
    expect((await only()).episodeNumber, 2);
  });

  test('clears a number the catalog says does not exist', () async {
    // Added via browse before the app stopped re-deriving: the old
    // extractor guessed a number for a film that has none.
    final id = await repo.insert(
      title: 'Das Original-Hörspiel zum Kinofilm',
      providerUri: filmNoEpisode,
      cardType: 'album',
    );
    await (db.update(db.cards)..where((t) => t.id.equals(id))).write(
      const CardsCompanion(episodeNumber: Value(5)),
    );

    final changed = await repo.reconcileEpisodeNumbers(catalog);

    expect(changed, 1);
    expect((await only()).episodeNumber, isNull);
  });

  test('leaves albums the catalog does not know alone', () async {
    final id = await repo.insert(
      title: 'Something uncurated',
      providerUri: 'spotify:album:zzzzzzzzzzzzzzzzzzzzzz',
      cardType: 'album',
    );
    await (db.update(db.cards)..where((t) => t.id.equals(id))).write(
      const CardsCompanion(episodeNumber: Value(3)),
    );

    expect(await repo.reconcileEpisodeNumbers(catalog), 0);
    expect((await only()).episodeNumber, 3);
  });

  test('leaves ARD items alone', () async {
    // ARD episode numbers come from ARD metadata, not the catalog.
    final id = await repo.insert(
      title: 'Some ARD episode',
      providerUri: 'ard:album:xyz',
      cardType: 'album',
      provider: ProviderType.ardAudiothek,
    );
    await (db.update(db.cards)..where((t) => t.id.equals(id))).write(
      const CardsCompanion(episodeNumber: Value(4)),
    );

    expect(await repo.reconcileEpisodeNumbers(catalog), 0);
    expect((await only()).episodeNumber, 4);
  });

  test('never touches the manual sort order', () async {
    final id = await repo.insert(
      title: 'Hui Buh',
      providerUri: huiBuhEp1,
      cardType: 'album',
    );
    await (db.update(db.cards)..where((t) => t.id.equals(id))).write(
      const CardsCompanion(sortOrder: Value(7), episodeNumber: Value(99)),
    );

    await repo.reconcileEpisodeNumbers(catalog);

    final card = await only();
    expect(card.episodeNumber, 1, reason: 'episode adopted from catalog');
    expect(card.sortOrder, 7, reason: 'the parent ordered this by hand');
  });

  test('is idempotent: a second pass writes nothing', () async {
    await repo.insert(
      title: 'Hui Buh',
      providerUri: huiBuhEp1,
      cardType: 'album',
    );
    expect(await repo.reconcileEpisodeNumbers(catalog), 1);
    expect(await repo.reconcileEpisodeNumbers(catalog), 0);
  });

  test('handles an empty database', () async {
    expect(await repo.reconcileEpisodeNumbers(catalog), 0);
  });
}
