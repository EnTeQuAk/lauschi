import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/ard/ard_api.dart';
import 'package:lauschi/core/ard/ard_models.dart';
import 'package:lauschi/core/database/app_database.dart';
import 'package:lauschi/core/database/content_importer.dart';
import 'package:lauschi/core/database/tile_item_repository.dart';
import 'package:lauschi/core/database/tile_repository.dart';

/// Fake [ArdApi] for testing pagination without real HTTP calls.
class _FakeArdApi extends ArdApi {
  _FakeArdApi({required this.pages});

  /// Pages to return in sequence. Each page is a list of items.
  final List<List<ArdItem>> pages;
  var _callCount = 0;

  @override
  Future<ArdItemPage> getItems({
    required String programSetId,
    int first = 20,
    String? after,
    bool publishedOnly = true,
  }) async {
    // Return pages in sequence. The first call (no after) returns page 0.
    // Subsequent calls return pages 1, 2, etc.
    final pageIndex = after == null ? 0 : ++_callCount;

    if (pageIndex >= pages.length) {
      // No more pages
      return ArdItemPage(
        items: [],
        hasNextPage: false,
        endCursor: null,
        totalCount: pages.expand((p) => p).length,
      );
    }

    final items = pages[pageIndex];
    final hasNextPage = pageIndex < pages.length - 1;

    return ArdItemPage(
      items: items,
      hasNextPage: hasNextPage,
      endCursor: hasNextPage ? 'cursor-$pageIndex' : null,
      totalCount: pages.expand((p) => p).length,
    );
  }
}

/// Create a test ARD item with required fields.
ArdItem _makeItem({
  required String id,
  required String title,
  required String audioUrl,
}) {
  return ArdItem(
    id: id,
    title: title,
    titleClean: title,
    duration: 600,
    publishDate: DateTime.now(),
    isPublished: true,
    imageUrl: null,
    programSetTitle: 'Test Show',
    audios: [ArdAudio(url: audioUrl, mimeType: 'audio/mp3')],
  );
}

void main() {
  late AppDatabase db;
  late ProviderContainer container;
  late TileRepository tiles;
  late TileItemRepository items;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    tiles = TileRepository(db);
    items = TileItemRepository(db);
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  /// Helper to create container with fake API.
  ProviderContainer _createContainer(ArdApi fakeApi) {
    return ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        tileRepositoryProvider.overrideWithValue(tiles),
        tileItemRepositoryProvider.overrideWithValue(items),
        ardApiProvider.overrideWithValue(fakeApi),
      ],
    );
  }

  group('importArdShow', () {
    test('imports single page of items without pagination', () async {
      final fakeApi = _FakeArdApi(
        pages: [
          [
            _makeItem(
              id: 'ep1',
              title: 'Episode 1',
              audioUrl: 'http://a/1.mp3',
            ),
            _makeItem(
              id: 'ep2',
              title: 'Episode 2',
              audioUrl: 'http://a/2.mp3',
            ),
            _makeItem(
              id: 'ep3',
              title: 'Episode 3',
              audioUrl: 'http://a/3.mp3',
            ),
          ],
        ],
      );

      container = _createContainer(fakeApi);
      final importer = container.read(contentImporterProvider.notifier);

      expect(await tiles.getAll(), isEmpty);
      expect(await items.getAll(), isEmpty);

      await importer.importArdShow(
        showId: 'test-show',
        showTitle: 'Test Show',
        showImageUrl: null,
        loadedItems: fakeApi.pages[0],
        hasMorePages: false,
        endCursor: null,
      );

      // All 3 episodes imported.
      expect(await items.getAll(), hasLength(3));
      expect(await tiles.getAll(), hasLength(1));

      final state = container.read(contentImporterProvider);
      expect(state, isA<ImportDone>());
      expect((state as ImportDone).added, 3);
    });

    test('paginates through multiple pages', () async {
      final fakeApi = _FakeArdApi(
        pages: [
          [
            _makeItem(id: 'ep1', title: 'Ep 1', audioUrl: 'http://a/1.mp3'),
            _makeItem(id: 'ep2', title: 'Ep 2', audioUrl: 'http://a/2.mp3'),
          ],
          [
            _makeItem(id: 'ep3', title: 'Ep 3', audioUrl: 'http://a/3.mp3'),
            _makeItem(id: 'ep4', title: 'Ep 4', audioUrl: 'http://a/4.mp3'),
          ],
          [
            _makeItem(id: 'ep5', title: 'Ep 5', audioUrl: 'http://a/5.mp3'),
          ],
        ],
      );

      container = _createContainer(fakeApi);
      final importer = container.read(contentImporterProvider.notifier);

      await importer.importArdShow(
        showId: 'multi-page-show',
        showTitle: 'Multi Page Show',
        showImageUrl: null,
        loadedItems: fakeApi.pages[0],
        hasMorePages: true,
        endCursor: 'cursor-0',
      );

      // All 5 episodes from 3 pages.
      expect(await items.getAll(), hasLength(5));

      final state = container.read(contentImporterProvider);
      expect((state as ImportDone).added, 5);
    });

    test('100-page safety limit prevents infinite loops', () async {
      // Create 102 pages - initial page + 101 more would be 102 total.
      // The 100-page limit in _loadRemainingPages caps additional pages.
      final pages = List.generate(
        102,
        (i) => [
          _makeItem(
            id: 'ep$i',
            title: 'Ep $i',
            audioUrl: 'http://a/$i.mp3',
          ),
        ],
      );

      final fakeApi = _FakeArdApi(pages: pages);
      container = _createContainer(fakeApi);
      final importer = container.read(contentImporterProvider.notifier);

      await importer.importArdShow(
        showId: 'infinite-show',
        showTitle: 'Infinite Show',
        showImageUrl: null,
        loadedItems: fakeApi.pages[0],
        hasMorePages: true,
        endCursor: 'cursor-0',
      );

      // Initial page (1) + 100 more from pagination = 101 items total.
      // Without the limit, it would be 102.
      final allItems = await items.getAll();
      expect(
        allItems.length,
        101,
        reason: 'should stop at 100 pagination pages',
      );
    });

    test('insertIfAbsent prevents duplicate URIs across imports', () async {
      // The key dedupe mechanism: insertIfAbsent checks providerUri.
      // Same episodes imported twice should only create DB rows once.
      final fakeApi = _FakeArdApi(
        pages: [
          [
            _makeItem(id: 'ep1', title: 'Ep 1', audioUrl: 'http://a/1.mp3'),
            _makeItem(id: 'ep2', title: 'Ep 2', audioUrl: 'http://a/2.mp3'),
          ],
        ],
      );

      container = _createContainer(fakeApi);
      final importer = container.read(contentImporterProvider.notifier);

      // First import
      await importer.importArdShow(
        showId: 'dedupe-show',
        showTitle: 'Dedupe Show',
        showImageUrl: null,
        loadedItems: fakeApi.pages[0],
        hasMorePages: false,
        endCursor: null,
      );

      expect(await items.getAll(), hasLength(2), reason: 'first import adds 2');

      // Reset importer state
      importer.acknowledge();

      // Second import with same items - URIs already exist
      await importer.importArdShow(
        showId: 'dedupe-show',
        showTitle: 'Dedupe Show 2', // Different tile title
        showImageUrl: null,
        loadedItems: fakeApi.pages[0],
        hasMorePages: false,
        endCursor: null,
      );

      // Should still be 2 items (same URIs), but now 2 tiles
      expect(
        await items.getAll(),
        hasLength(2),
        reason: 'second import reuses existing items',
      );
      expect(
        await tiles.getAll(),
        hasLength(2),
        reason: 'second tile created, same items reused',
      );
    });

    test('filters out items without audio URLs', () async {
      final fakeApi = _FakeArdApi(
        pages: [
          [
            _makeItem(id: 'ep1', title: 'Ep 1', audioUrl: 'http://a/1.mp3'),
            // Item without playable audio
            ArdItem(
              id: 'ep2',
              title: 'Ep 2 (No Audio)',
              titleClean: 'Ep 2 (No Audio)',
              duration: 600,
              publishDate: DateTime.now(),
              isPublished: true,
              imageUrl: null,
              programSetTitle: 'Test Show',
              audios: [], // Empty audios list
            ),
            _makeItem(id: 'ep3', title: 'Ep 3', audioUrl: 'http://a/3.mp3'),
          ],
        ],
      );

      container = _createContainer(fakeApi);
      final importer = container.read(contentImporterProvider.notifier);

      await importer.importArdShow(
        showId: 'no-audio-show',
        showTitle: 'No Audio Show',
        showImageUrl: null,
        loadedItems: fakeApi.pages[0],
        hasMorePages: false,
        endCursor: null,
      );

      // Only 2 items with audio URLs imported.
      expect(await items.getAll(), hasLength(2));

      final state = container.read(contentImporterProvider);
      expect((state as ImportDone).added, 2);
    });

    test('import fails gracefully and reports error', () async {
      // Fake API that throws on pagination
      final throwingApi = _ThrowingArdApi();
      container = _createContainer(throwingApi);
      final importer = container.read(contentImporterProvider.notifier);

      await importer.importArdShow(
        showId: 'error-show',
        showTitle: 'Error Show',
        showImageUrl: null,
        loadedItems: [],
        hasMorePages: true,
        endCursor: 'cursor-0',
      );

      final state = container.read(contentImporterProvider);
      expect(state, isA<ImportFailed>());
    });
  });
}

/// API that always throws (for error handling tests).
class _ThrowingArdApi extends ArdApi {
  @override
  Future<ArdItemPage> getItems({
    required String programSetId,
    int first = 20,
    String? after,
    bool publishedOnly = true,
  }) async {
    throw Exception('Simulated API failure');
  }
}
