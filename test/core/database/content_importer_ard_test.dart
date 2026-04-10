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
///
/// Uses cursor-based lookup (matching the real API's opaque cursor contract)
/// rather than a call counter. Page 0 is returned for `after: null`, then
/// the `endCursor` from each response must be passed back to get the next page.
class _FakeArdApi extends ArdApi {
  _FakeArdApi({required this.pages});

  /// Pages to return in sequence. Each page is a list of items.
  final List<List<ArdItem>> pages;

  /// Cursors returned so far, mapped to the page index they unlock.
  /// Page 0 returns endCursor 'cursor:1' (unlocks page 1), etc.
  static String _cursorFor(int nextPageIndex) => 'cursor:$nextPageIndex';

  @override
  Future<ArdItemPage> getItems({
    required String programSetId,
    int first = 20,
    String? after,
    bool publishedOnly = true,
  }) async {
    // Resolve page index from cursor. Page 0 has no cursor (first request).
    final int pageIndex;
    if (after == null) {
      pageIndex = 0;
    } else {
      // Parse 'cursor:N' to get page N. Reject unknown cursor formats
      // to catch bugs where the wrong cursor is forwarded.
      final parts = after.split(':');
      if (parts.length != 2 || parts[0] != 'cursor') {
        throw ArgumentError('Unknown cursor format: $after');
      }
      pageIndex = int.parse(parts[1]);
    }

    if (pageIndex >= pages.length) {
      return const ArdItemPage(items: []);
    }

    final items = pages[pageIndex];
    final hasNextPage = pageIndex < pages.length - 1;

    return ArdItemPage(
      items: items,
      hasNextPage: hasNextPage,
      endCursor: hasNextPage ? _cursorFor(pageIndex + 1) : null,
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
  ProviderContainer createContainer(ArdApi fakeApi) {
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

      container = createContainer(fakeApi);
      final importer = container.read(contentImporterProvider.notifier);

      expect(await tiles.getAll(), isEmpty);
      expect(await items.getAll(), isEmpty);

      await importer.importArdShow(
        showId: 'test-show',
        showTitle: 'Test Show',
        showImageUrl: null,
        loadedItems: fakeApi.pages[0],
        hasMorePages: false,
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

      container = createContainer(fakeApi);
      final importer = container.read(contentImporterProvider.notifier);

      await importer.importArdShow(
        showId: 'multi-page-show',
        showTitle: 'Multi Page Show',
        showImageUrl: null,
        loadedItems: fakeApi.pages[0],
        hasMorePages: true,
        endCursor: 'cursor:1',
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
      container = createContainer(fakeApi);
      final importer = container.read(contentImporterProvider.notifier);

      await importer.importArdShow(
        showId: 'infinite-show',
        showTitle: 'Infinite Show',
        showImageUrl: null,
        loadedItems: fakeApi.pages[0],
        hasMorePages: true,
        endCursor: 'cursor:1',
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

      container = createContainer(fakeApi);
      final importer = container.read(contentImporterProvider.notifier);

      // First import
      await importer.importArdShow(
        showId: 'dedupe-show',
        showTitle: 'Dedupe Show',
        showImageUrl: null,
        loadedItems: fakeApi.pages[0],
        hasMorePages: false,
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
              programSetTitle: 'Test Show',
              audios: [], // Empty audios list
            ),
            _makeItem(id: 'ep3', title: 'Ep 3', audioUrl: 'http://a/3.mp3'),
          ],
        ],
      );

      container = createContainer(fakeApi);
      final importer = container.read(contentImporterProvider.notifier);

      await importer.importArdShow(
        showId: 'no-audio-show',
        showTitle: 'No Audio Show',
        showImageUrl: null,
        loadedItems: fakeApi.pages[0],
        hasMorePages: false,
      );

      // Only 2 items with audio URLs imported.
      expect(await items.getAll(), hasLength(2));

      final state = container.read(contentImporterProvider);
      expect((state as ImportDone).added, 2);
    });

    test('import fails gracefully and reports error', () async {
      // Fake API that throws on pagination
      final throwingApi = _ThrowingArdApi();
      container = createContainer(throwingApi);
      final importer = container.read(contentImporterProvider.notifier);

      await importer.importArdShow(
        showId: 'error-show',
        showTitle: 'Error Show',
        showImageUrl: null,
        loadedItems: [],
        hasMorePages: true,
        endCursor: 'cursor:1',
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
  }) {
    throw Exception('Simulated API failure');
  }
}
