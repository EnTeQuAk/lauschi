import 'package:flutter/foundation.dart';
import 'package:lauschi/core/catalog/catalog_service.dart';
import 'package:lauschi/core/catalog/catalog_source.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/providers/provider_type.dart';
import 'package:lauschi/core/spotify/spotify_api.dart';
import 'package:lauschi/core/spotify/spotify_session.dart';
import 'package:lauschi/features/parent/screens/browse_catalog/widgets/catalog_helpers.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'catalog_search_notifier.g.dart';

const _tag = 'CatalogSearch';

/// Max hero cards shown in unified search results.
const maxCatalogResults = 4;

// ── Search mode ─────────────────────────────────────────────────────────────

enum CatalogSearchMode { album, playlist }

// ── State ───────────────────────────────────────────────────────────────────

@immutable
class CatalogSearchState {
  const CatalogSearchState({
    this.searchMode = CatalogSearchMode.album,
    this.albums = const [],
    this.playlists = const [],
    this.catalogMatches = const [],
    this.heroSeries = const [],
    this.totalCatalogHits = 0,
    this.isSearching = false,
    this.hasSearched = false,
  });

  final CatalogSearchMode searchMode;
  final List<CatalogAlbumResult> albums;
  final List<SpotifyPlaylist> playlists;
  final List<CatalogMatch?> catalogMatches;
  final List<CatalogSeries> heroSeries;
  final int totalCatalogHits;
  final bool isSearching;
  final bool hasSearched;

  bool get isMusicMode => searchMode == CatalogSearchMode.playlist;

  CatalogSearchState copyWith({
    CatalogSearchMode? searchMode,
    List<CatalogAlbumResult>? albums,
    List<SpotifyPlaylist>? playlists,
    List<CatalogMatch?>? catalogMatches,
    List<CatalogSeries>? heroSeries,
    int? totalCatalogHits,
    bool? isSearching,
    bool? hasSearched,
  }) {
    return CatalogSearchState(
      searchMode: searchMode ?? this.searchMode,
      albums: albums ?? this.albums,
      playlists: playlists ?? this.playlists,
      catalogMatches: catalogMatches ?? this.catalogMatches,
      heroSeries: heroSeries ?? this.heroSeries,
      totalCatalogHits: totalCatalogHits ?? this.totalCatalogHits,
      isSearching: isSearching ?? this.isSearching,
      hasSearched: hasSearched ?? this.hasSearched,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CatalogSearchState &&
          runtimeType == other.runtimeType &&
          searchMode == other.searchMode &&
          listEquals(albums, other.albums) &&
          listEquals(playlists, other.playlists) &&
          listEquals(catalogMatches, other.catalogMatches) &&
          listEquals(heroSeries, other.heroSeries) &&
          totalCatalogHits == other.totalCatalogHits &&
          isSearching == other.isSearching &&
          hasSearched == other.hasSearched;

  @override
  int get hashCode => Object.hash(
    searchMode,
    Object.hashAll(albums),
    Object.hashAll(playlists),
    Object.hashAll(catalogMatches),
    Object.hashAll(heroSeries),
    totalCatalogHits,
    isSearching,
    hasSearched,
  );
}

// ── Notifier ────────────────────────────────────────────────────────────────

@riverpod
class CatalogSearch extends _$CatalogSearch {
  int _generation = 0;

  @override
  CatalogSearchState build(ProviderType provider) {
    _generation = 0;
    return const CatalogSearchState();
  }

  /// Run album search + catalog matching + hero series computation.
  Future<void> search(String query, CatalogSource source) async {
    state = state.copyWith(isSearching: true);
    final gen = ++_generation;

    try {
      final albums = await source.searchAlbums(query);
      if (gen != _generation) return;

      final catalog = ref.read(catalogServiceProvider).value;
      final matches =
          catalog != null
              ? albums
                  .map(
                    (a) => catalog.match(
                      a.name,
                      albumId: a.id,
                      albumProvider: a.provider,
                    ),
                  )
                  .toList()
              : List<CatalogMatch?>.filled(albums.length, null);

      final catalogHits = matches.whereType<CatalogMatch>().length;
      Log.info(
        _tag,
        'Search',
        data: {
          'query': query,
          'results': '${albums.length}',
          'catalogHits': '$catalogHits',
        },
      );

      final isMusicMode = state.isMusicMode;
      final allCatalogHits =
          catalog
              ?.search(query)
              .where((s) => s.hasCuratedAlbumsFor(source.provider))
              .where((s) => isMusicMode ? s.isMusic : !s.isMusic)
              .toList() ??
          [];

      final indices = sortByCatalogMatch(matches, albums.length);
      final sortedAlbums = [for (final i in indices) albums[i]];
      final sortedMatches = [for (final i in indices) matches[i]];

      state = state.copyWith(
        albums: sortedAlbums,
        playlists: const [],
        catalogMatches: sortedMatches,
        heroSeries: allCatalogHits.take(maxCatalogResults).toList(),
        totalCatalogHits: allCatalogHits.length,
        isSearching: false,
        hasSearched: true,
      );
    } on Exception catch (e) {
      Log.error(_tag, 'Search failed', exception: e);
      if (gen == _generation) {
        state = state.copyWith(isSearching: false);
      }
      rethrow;
    }
  }

  /// Append playlist results (Spotify-only, Musik mode).
  Future<void> searchPlaylists(String query, SpotifySession session) async {
    final gen = ++_generation;
    final result = await session.api.searchPlaylists(query);
    if (gen != _generation) return;
    Log.info(
      _tag,
      'Search (playlists)',
      data: {'query': query, 'results': '${result.playlists.length}'},
    );
    state = state.copyWith(
      playlists: result.playlists,
      isSearching: false,
    );
  }

  /// Change search mode. Resets results.
  void setMode(CatalogSearchMode mode) {
    _generation++;
    state = CatalogSearchState(searchMode: mode);
  }

  /// Clear all search state.
  void reset() {
    _generation++;
    state = CatalogSearchState(searchMode: state.searchMode);
  }
}
