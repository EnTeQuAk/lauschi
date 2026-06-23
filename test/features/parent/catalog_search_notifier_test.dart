import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/catalog/catalog_service.dart';
import 'package:lauschi/core/catalog/catalog_source.dart';
import 'package:lauschi/core/providers/provider_type.dart';
import 'package:lauschi/features/parent/screens/browse_catalog/catalog_search_notifier.dart';

// ── Fakes ───────────────────────────────────────────────────────────────────

class _FakeSource implements CatalogSource {
  _FakeSource({this.albums = const [], this.delay});

  final List<CatalogAlbumResult> albums;
  final Duration? delay;
  int searchCount = 0;

  @override
  ProviderType get provider => ProviderType.spotify;

  @override
  Future<List<CatalogAlbumResult>> searchAlbums(String query) async {
    searchCount++;
    if (delay != null) await Future<void>.delayed(delay!);
    return albums;
  }

  @override
  Future<CatalogAlbumResult?> getAlbum(String albumId) async => null;

  @override
  Future<List<CatalogTrackResult>> getAlbumTracks(String albumId) async => [];

  @override
  Future<Map<String, String>> getAlbumCovers(
    List<String> albumIds, {
    int size = 300,
  }) async => {};

  @override
  void cancelCover(String albumId) {}
}

class _FailingSource extends _FakeSource {
  @override
  Future<List<CatalogAlbumResult>> searchAlbums(String query) {
    throw Exception('network error');
  }
}

CatalogAlbumResult _album(String id, {String name = 'Album'}) =>
    CatalogAlbumResult(
      id: id,
      name: name,
      artistName: 'Artist',
      artistIds: const [],
      provider: ProviderType.spotify,
    );

// ── Helpers ─────────────────────────────────────────────────────────────────

/// Create a container with a listener that keeps the search provider alive
/// (prevents auto-dispose). Optionally override catalogServiceProvider.
({ProviderContainer container, List<CatalogSearchState> states}) setup({
  List<Override> overrides = const [],
  ProviderType provider = ProviderType.spotify,
}) {
  final container = ProviderContainer(overrides: overrides);
  final states = <CatalogSearchState>[];
  container.listen(
    catalogSearchProvider(provider),
    (_, next) => states.add(next),
  );
  return (container: container, states: states);
}

// ── Tests ───────────────────────────────────────────────────────────────────

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CatalogSearchState', () {
    test('defaults are sensible', () {
      const s = CatalogSearchState();
      expect(s.searchMode, CatalogSearchMode.album);
      expect(s.albums, isEmpty);
      expect(s.playlists, isEmpty);
      expect(s.catalogMatches, isEmpty);
      expect(s.heroSeries, isEmpty);
      expect(s.totalCatalogHits, 0);
      expect(s.isSearching, isFalse);
      expect(s.hasSearched, isFalse);
      expect(s.isMusicMode, isFalse);
    });

    test('isMusicMode reflects playlist search mode', () {
      const s = CatalogSearchState(searchMode: CatalogSearchMode.playlist);
      expect(s.isMusicMode, isTrue);
    });

    test('copyWith preserves unchanged fields', () {
      final albums = [_album('a1')];
      final s = CatalogSearchState(albums: albums, isSearching: true);
      final s2 = s.copyWith(isSearching: false);
      expect(s2.albums, same(albums));
      expect(s2.isSearching, isFalse);
    });

    test('equality compares scalar fields', () {
      const a = CatalogSearchState(isSearching: true, totalCatalogHits: 5);
      const b = CatalogSearchState(isSearching: true, totalCatalogHits: 5);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('different states are not equal', () {
      const a = CatalogSearchState(isSearching: true);
      const b = CatalogSearchState();
      expect(a, isNot(equals(b)));
    });

    test('equality on lists uses content, not identity', () {
      const matches = [null, null];
      const a = CatalogSearchState(catalogMatches: matches);
      final b = CatalogSearchState(catalogMatches: List.of(matches));
      expect(a, equals(b));
    });
  });

  group('CatalogSearch.search', () {
    late ProviderContainer container;
    tearDown(() => container.dispose());

    test('sets isSearching then hasSearched on completion', () async {
      final s = setup();
      container = s.container;
      final notifier = container.read(
        catalogSearchProvider(ProviderType.spotify).notifier,
      );

      await notifier.search('test', _FakeSource(albums: [_album('a1')]));

      expect(s.states.length, greaterThanOrEqualTo(2));
      expect(s.states.first.isSearching, isTrue);
      expect(s.states.last.isSearching, isFalse);
      expect(s.states.last.hasSearched, isTrue);
      expect(s.states.last.albums, hasLength(1));
    });

    test('produces null matches when catalog not loaded', () async {
      final s = setup();
      container = s.container;
      final notifier = container.read(
        catalogSearchProvider(ProviderType.spotify).notifier,
      );

      await notifier.search(
        'test',
        _FakeSource(albums: [_album('a1'), _album('a2')]),
      );

      final state = container.read(catalogSearchProvider(ProviderType.spotify));
      expect(state.albums, hasLength(2));
      expect(state.catalogMatches, hasLength(2));
      expect(
        state.catalogMatches.every((m) => m == null),
        isTrue,
        reason: 'no catalog loaded, all matches should be null',
      );
      expect(state.heroSeries, isEmpty);
    });

    test('matches albums against real catalog', () async {
      final catalog = await CatalogService.load();
      final s = setup(
        overrides: [
          catalogServiceProvider.overrideWithValue(AsyncData(catalog)),
        ],
      );
      container = s.container;

      final notifier = container.read(
        catalogSearchProvider(ProviderType.spotify).notifier,
      );

      // Real curated Spotify album ID: Yakari Folge 1.
      final source = _FakeSource(
        albums: [
          _album('25u9Clfj4qnEJD3jjxOwPR', name: 'Yakari Folge 1'),
          _album('not-in-catalog', name: 'Random Album'),
        ],
      );

      await notifier.search('yakari', source);

      final state = container.read(catalogSearchProvider(ProviderType.spotify));

      final matchedCount = state.catalogMatches.where((m) => m != null).length;
      expect(matchedCount, 1, reason: 'Yakari album matched, random did not');

      expect(
        state.catalogMatches.first,
        isNotNull,
        reason: 'matched album sorted to front',
      );
      expect(state.catalogMatches.last, isNull);

      expect(
        state.heroSeries.any((s) => s.id == 'yakari'),
        isTrue,
        reason: 'Yakari should appear in hero series',
      );
    });

    test('clears previous playlists on album search', () async {
      final s = setup();
      container = s.container;
      final notifier = container.read(
        catalogSearchProvider(ProviderType.spotify).notifier,
      );

      await notifier.search('test', _FakeSource(albums: [_album('a1')]));

      final state = container.read(catalogSearchProvider(ProviderType.spotify));
      expect(state.playlists, isEmpty);
    });

    test('rethrows on search failure and resets isSearching', () async {
      final s = setup();
      container = s.container;
      final notifier = container.read(
        catalogSearchProvider(ProviderType.spotify).notifier,
      );

      await expectLater(
        notifier.search('boom', _FailingSource()),
        throwsA(isA<Exception>()),
      );

      final state = container.read(catalogSearchProvider(ProviderType.spotify));
      expect(state.isSearching, isFalse, reason: 'reset after error');
      expect(state.hasSearched, isFalse, reason: 'never completed');
    });
  });

  group('CatalogSearch.setMode', () {
    late ProviderContainer container;
    tearDown(() => container.dispose());

    test('resets all results and sets new mode', () async {
      final s = setup();
      container = s.container;
      final notifier = container.read(
        catalogSearchProvider(ProviderType.spotify).notifier,
      );

      await notifier.search('test', _FakeSource(albums: [_album('a1')]));
      notifier.setMode(CatalogSearchMode.playlist);

      final state = container.read(catalogSearchProvider(ProviderType.spotify));
      expect(state.searchMode, CatalogSearchMode.playlist);
      expect(state.albums, isEmpty);
      expect(state.hasSearched, isFalse);
    });
  });

  group('CatalogSearch.reset', () {
    late ProviderContainer container;
    tearDown(() => container.dispose());

    test('clears results but preserves mode', () async {
      final s = setup();
      container = s.container;
      final notifier = container.read(
        catalogSearchProvider(ProviderType.spotify).notifier,
      )..setMode(CatalogSearchMode.playlist);

      await notifier.search('test', _FakeSource(albums: [_album('a1')]));
      notifier.reset();

      final state = container.read(catalogSearchProvider(ProviderType.spotify));
      expect(state.searchMode, CatalogSearchMode.playlist);
      expect(state.albums, isEmpty);
      expect(state.hasSearched, isFalse);
    });
  });

  group('generation counter (stale result suppression)', () {
    late ProviderContainer container;
    tearDown(() => container.dispose());

    test('reset during search discards results', () async {
      final s = setup();
      container = s.container;
      final notifier = container.read(
        catalogSearchProvider(ProviderType.spotify).notifier,
      );

      final source = _FakeSource(
        albums: [_album('a1')],
        delay: const Duration(milliseconds: 50),
      );

      final searchFuture = notifier.search('slow', source);
      notifier.reset();
      await searchFuture;

      final state = container.read(catalogSearchProvider(ProviderType.spotify));
      expect(
        state.albums,
        isEmpty,
        reason: 'stale search result discarded after reset',
      );
      expect(state.hasSearched, isFalse);
    });

    test('second search supersedes first', () async {
      final s = setup();
      container = s.container;
      final notifier = container.read(
        catalogSearchProvider(ProviderType.spotify).notifier,
      );

      final slowSource = _FakeSource(
        albums: [_album('slow')],
        delay: const Duration(milliseconds: 50),
      );
      final fastSource = _FakeSource(albums: [_album('fast')]);

      final first = notifier.search('slow', slowSource);
      final second = notifier.search('fast', fastSource);

      await Future.wait([first, second]);

      final state = container.read(catalogSearchProvider(ProviderType.spotify));
      expect(state.albums, hasLength(1));
      expect(
        state.albums.first.id,
        'fast',
        reason: 'second search wins over first',
      );
    });
  });

  group('provider family keying', () {
    late ProviderContainer container;
    tearDown(() => container.dispose());

    test('different providers get independent state', () async {
      final spotifySetup = setup();
      container =
          spotifySetup.container..listen(
            catalogSearchProvider(ProviderType.appleMusic),
            (_, _) {},
          );

      final spotifyNotifier = container.read(
        catalogSearchProvider(ProviderType.spotify).notifier,
      );
      final appleNotifier = container.read(
        catalogSearchProvider(ProviderType.appleMusic).notifier,
      );

      await spotifyNotifier.search(
        'test',
        _FakeSource(albums: [_album('s1'), _album('s2')]),
      );

      final spotifyState = container.read(
        catalogSearchProvider(ProviderType.spotify),
      );
      final appleState = container.read(
        catalogSearchProvider(ProviderType.appleMusic),
      );

      expect(spotifyState.albums, hasLength(2));
      expect(appleState.albums, isEmpty, reason: 'untouched provider');

      await appleNotifier.search(
        'other',
        _FakeSource(albums: [_album('a1')]),
      );

      final spotifyAfter = container.read(
        catalogSearchProvider(ProviderType.spotify),
      );
      expect(
        spotifyAfter.albums,
        hasLength(2),
        reason: 'Spotify state unchanged',
      );
    });
  });
}
