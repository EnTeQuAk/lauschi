import 'dart:async' show Timer, unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lauschi/core/catalog/catalog_service.dart';
import 'package:lauschi/core/catalog/catalog_source.dart';
import 'package:lauschi/core/database/app_database.dart' as db;
import 'package:lauschi/core/database/content_importer.dart';
import 'package:lauschi/core/database/tile_item_repository.dart';
import 'package:lauschi/core/database/tile_repository.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/providers/provider_type.dart';
import 'package:lauschi/core/router/app_router.dart';
import 'package:lauschi/core/spotify/spotify_api.dart';
import 'package:lauschi/core/spotify/spotify_session.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/parent/widgets/catalog/album_detail_sheet.dart';
import 'package:lauschi/features/parent/widgets/catalog/batch_add_banner.dart';
import 'package:lauschi/features/parent/widgets/catalog/catalog_hero_card.dart';
import 'package:lauschi/features/parent/widgets/catalog/collapsible_divider.dart';
import 'package:lauschi/features/parent/widgets/catalog/curated_series_card.dart';
import 'package:lauschi/features/parent/widgets/catalog/playlist_detail_sheet.dart';
import 'package:lauschi/features/parent/widgets/catalog/playlist_result_tile.dart';
import 'package:lauschi/features/parent/widgets/catalog/search_result_tile.dart';

const _tag = 'BrowseCatalog';

/// Max hero cards shown in unified search results.
const _maxCatalogResults = 4;

// ── Unified browse + search screen ──────────────────────────────────────────

/// Curated catalog grid with inline Spotify search.
///
/// Default view shows the curated series grid with a search bar at the top.
/// When the user types a query, the grid is replaced by live Spotify results.
/// This replaces the old separate AddCardScreen for the general add flow.
///
/// When [autoAssignTileId] is set (via TileEditScreen FAB), every added
/// card is silently assigned to that group.
///
/// When [embedded] is true, returns just the body content without
/// Scaffold/AppBar (for use inside tabbed containers).
class BrowseCatalogScreen extends ConsumerStatefulWidget {
  const BrowseCatalogScreen({
    required this.catalogSource,
    super.key,
    this.autoAssignTileId,
    this.embedded = false,
  });

  final CatalogSource catalogSource;
  final String? autoAssignTileId;
  final bool embedded;

  @override
  ConsumerState<BrowseCatalogScreen> createState() =>
      _BrowseCatalogScreenState();
}

class _BrowseCatalogScreenState extends ConsumerState<BrowseCatalogScreen>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => widget.embedded;

  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();
  Timer? _debounce;

  // Search state
  _SearchMode _searchMode = _SearchMode.album;
  List<CatalogAlbumResult> _albumResults = [];
  List<SpotifyPlaylist> _playlistResults = [];
  List<CatalogMatch?> _catalogMatches = [];
  bool _isSearching = false;
  bool _hasSearched = false;
  int _searchGeneration = 0;

  // Hero card state (unified search layout, #195)
  List<CatalogSeries> _heroSeries = [];
  int _totalCatalogHits = 0;
  bool _isMatchingExpanded = false;

  /// Album indices whose catalog match belongs to a hero series.
  List<int> get _matchingIndices {
    final heroIds = _heroSeries.map((h) => h.id).toSet();
    return [
      for (var i = 0; i < _albumResults.length; i++)
        if (i < _catalogMatches.length &&
            _catalogMatches[i] != null &&
            heroIds.contains(_catalogMatches[i]!.series.id))
          i,
    ];
  }

  /// Album indices that don't match any hero series (novel content).
  List<int> get _nonMatchingIndices {
    final heroIds = _heroSeries.map((h) => h.id).toSet();
    return [
      for (var i = 0; i < _albumResults.length; i++)
        if (i >= _catalogMatches.length ||
            _catalogMatches[i] == null ||
            !heroIds.contains(_catalogMatches[i]!.series.id))
          i,
    ];
  }

  // Add state
  final _addedUris = <String>{};
  final _createdSeriesTitles = <String>{};
  db.Tile? _autoGroup;

  // Snackbar batching
  Timer? _snackTimer;
  int _pendingAdded = 0;
  final _pendingAssignedCardIds = <String>[];
  String _lastSeriesTitle = '';

  bool get _isSearchActive => _searchController.text.trim().isNotEmpty;
  bool get _isAutoAssignMode => widget.autoAssignTileId != null;

  @override
  void initState() {
    super.initState();
    unawaited(_loadExistingUris());
    if (_isAutoAssignMode) {
      unawaited(_loadAutoGroup());
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    _debounce?.cancel();
    _snackTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadExistingUris() async {
    final all = await ref.read(tileItemRepositoryProvider).getAll();
    final groups = await ref.read(tileRepositoryProvider).getAll();
    if (mounted) {
      setState(() {
        _addedUris.addAll(all.map((c) => c.providerUri));
        _createdSeriesTitles.addAll(
          groups.map((g) => g.title.toLowerCase()),
        );
      });
    }
  }

  Future<void> _loadAutoGroup() async {
    final group = await ref
        .read(tileRepositoryProvider)
        .getById(widget.autoAssignTileId!);
    if (mounted) setState(() => _autoGroup = group);
  }

  // ---------------------------------------------------------------------------
  // Search
  // ---------------------------------------------------------------------------

  void _onSearchChanged(String query) {
    _debounce?.cancel();
    if (query.trim().isEmpty) {
      setState(() {
        _albumResults = [];
        _playlistResults = [];
        _catalogMatches = [];
        _heroSeries = [];
        _totalCatalogHits = 0;
        _isMatchingExpanded = false;
        _isSearching = false;
        _hasSearched = false;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 400), () async {
      await _search(query.trim());
    });
  }

  Future<void> _search(String query) async {
    setState(() => _isSearching = true);
    try {
      // Always search albums (works for all providers and both modes).
      await _searchAlbums(query);
      // In Musik mode on Spotify, also search playlists and append them.
      // Parents may have curated playlists they want to add.
      if (_searchMode == _SearchMode.playlist &&
          _source.provider == ProviderType.spotify) {
        await _searchPlaylists(query);
      }
    } on Exception catch (e) {
      Log.error(_tag, 'Search failed', exception: e);
      if (mounted) setState(() => _isSearching = false);
    }
  }

  CatalogSource get _source => widget.catalogSource;

  Future<void> _searchAlbums(String query) async {
    final source = _source;
    final gen = ++_searchGeneration;
    final albums = await source.searchAlbums(query);
    if (!mounted || gen != _searchGeneration) return;
    final catalog = ref.read(catalogServiceProvider).value;
    final matches =
        catalog != null
            ? albums
                .map(
                  (a) => catalog.match(a.name, albumArtistIds: a.artistIds),
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
    // Hero series from catalog search (instant, local).
    // Filter by content type to match the active tab.
    final isMusicMode = _searchMode == _SearchMode.playlist;
    final allCatalogHits =
        catalog
            ?.search(query)
            .where((s) => s.hasCuratedAlbumsFor(_source.provider))
            .where((s) => isMusicMode ? s.isMusic : !s.isMusic)
            .toList() ??
        [];
    // Sort: catalog-matched albums first, then unmatched.
    // This ensures curated content (Senta's actual albums) appears above
    // unrelated results (Brazilian funk "Vai Sentar") that match the query.
    final indices = List.generate(albums.length, (i) => i)..sort((a, b) {
      final aMatch = matches[a] != null;
      final bMatch = matches[b] != null;
      if (aMatch != bMatch) return aMatch ? -1 : 1;
      return 0; // preserve provider's relevance order within each group
    });
    final sortedAlbums = [for (final i in indices) albums[i]];
    final sortedMatches = [for (final i in indices) matches[i]];

    setState(() {
      _albumResults = sortedAlbums;
      _playlistResults = [];
      _catalogMatches = sortedMatches;
      _heroSeries = allCatalogHits.take(_maxCatalogResults).toList();
      _totalCatalogHits = allCatalogHits.length;
      _isMatchingExpanded = false;
      _isSearching = false;
      _hasSearched = true;
    });
  }

  Future<void> _searchPlaylists(String query) async {
    final gen = ++_searchGeneration;
    final result = await ref
        .read(spotifySessionProvider.notifier)
        .api
        .searchPlaylists(query);
    if (!mounted || gen != _searchGeneration) return;
    Log.info(
      _tag,
      'Search (playlists)',
      data: {'query': query, 'results': '${result.playlists.length}'},
    );
    setState(() {
      _playlistResults = result.playlists;
      // Don't clear _albumResults — playlist search runs after album search
      // in Musik mode, appending playlists below albums.
      _isSearching = false;
    });
  }

  void _setSearchMode(_SearchMode mode) {
    if (mode == _searchMode) return;
    _searchGeneration++; // Invalidate in-flight requests for old mode
    setState(() {
      _searchMode = mode;
      _albumResults = [];
      _playlistResults = [];
      _catalogMatches = [];
      _heroSeries = [];
      _totalCatalogHits = 0;
      _isMatchingExpanded = false;
      _hasSearched = false;
    });
    final query = _searchController.text.trim();
    if (query.isNotEmpty) {
      _debounce?.cancel();
      unawaited(_search(query));
    }
  }

  void _clearSearch() {
    _searchController.clear();
    _searchFocusNode.unfocus();
    setState(() {
      _albumResults = [];
      _playlistResults = [];
      _catalogMatches = [];
      _heroSeries = [];
      _totalCatalogHits = 0;
      _isMatchingExpanded = false;
      _isSearching = false;
      _hasSearched = false;
    });
  }

  // ---------------------------------------------------------------------------
  // Add logic
  // ---------------------------------------------------------------------------

  Future<void> _handleAddTap(
    CatalogAlbumResult album,
    CatalogMatch? match,
  ) async {
    if (_isAutoAssignMode) {
      await _addAndAssign(album, widget.autoAssignTileId!, match);
      return;
    }

    if (match != null) {
      final groupId = await _findOrCreateGroup(match.series.title);
      await _addAndAssign(album, groupId, match, showUndo: true);
      return;
    }

    await _addOnly(album);
  }

  Future<void> _handleAddAll(String seriesTitle) async {
    final groupId =
        _isAutoAssignMode
            ? widget.autoAssignTileId!
            : await _findOrCreateGroup(seriesTitle);
    if (!mounted) return;
    var count = 0;
    for (var i = 0; i < _albumResults.length; i++) {
      final album = _albumResults[i];
      if (_addedUris.contains(album.providerUri)) continue;
      final match = i < _catalogMatches.length ? _catalogMatches[i] : null;
      // Compares by title (not ID) because batchSeries is title-based.
      if (match?.series.title != seriesTitle) continue;
      await _addAndAssign(album, groupId, match, silent: true);
      count++;
    }
    if (mounted && count > 0) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: Text('$count Einträge zu »$seriesTitle« hinzugefügt'),
            duration: const Duration(seconds: 3),
            behavior: SnackBarBehavior.floating,
          ),
        );
    }
  }

  Future<String> _findOrCreateGroup(String seriesTitle) async {
    final groupRepo = ref.read(tileRepositoryProvider);
    final existing = await groupRepo.findByTitle(seriesTitle);
    if (existing != null) return existing.id;
    return groupRepo.insert(title: seriesTitle);
  }

  Future<void> _addAndAssign(
    CatalogAlbumResult album,
    String groupId,
    CatalogMatch? match, {
    bool showUndo = false,
    bool silent = false,
  }) async {
    final cardId = await ref
        .read(tileItemRepositoryProvider)
        .insertIfAbsent(
          title: album.name,
          providerUri: album.providerUri,
          cardType: 'album',
          coverUrl: album.artworkUrlForSize(600),
          spotifyArtistIds: album.artistIds,
          totalTracks: album.totalTracks,
        );
    await ref
        .read(tileItemRepositoryProvider)
        .assignToTile(
          itemId: cardId,
          tileId: groupId,
          episodeNumber: match?.episodeNumber,
        );
    if (!mounted) return;
    setState(() => _addedUris.add(album.providerUri));

    if (silent) return;

    if (showUndo) {
      _pendingAssignedCardIds.add(cardId);
      _lastSeriesTitle = match?.series.title ?? '';
      _snackTimer?.cancel();
      _snackTimer = Timer(const Duration(milliseconds: 500), () {
        if (!mounted) return;
        final ids = List<String>.of(_pendingAssignedCardIds);
        _pendingAssignedCardIds.clear();
        final label =
            ids.length == 1
                ? 'Zu »$_lastSeriesTitle« hinzugefügt'
                : '${ids.length} Einträge zu »$_lastSeriesTitle« hinzugefügt';
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(
            SnackBar(
              content: Text(label),
              behavior: SnackBarBehavior.floating,
              action: SnackBarAction(
                label: 'Rückgängig',
                onPressed: () {
                  final repo = ref.read(tileItemRepositoryProvider);
                  for (final id in ids) {
                    unawaited(repo.removeFromTile(id));
                  }
                },
              ),
            ),
          );
      });
    } else {
      _pendingAdded++;
      _snackTimer?.cancel();
      _snackTimer = Timer(const Duration(milliseconds: 500), () {
        if (!mounted) return;
        final n = _pendingAdded;
        _pendingAdded = 0;
        final label =
            n == 1 ? '${album.name} hinzugefügt' : '$n Einträge hinzugefügt';
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(
            SnackBar(
              content: Text(label),
              duration: const Duration(seconds: 2),
              behavior: SnackBarBehavior.floating,
            ),
          );
      });
    }
  }

  Future<void> _addOnly(CatalogAlbumResult album) async {
    await ref
        .read(tileItemRepositoryProvider)
        .insertIfAbsent(
          title: album.name,
          providerUri: album.providerUri,
          cardType: 'album',
          coverUrl: album.artworkUrlForSize(600),
          spotifyArtistIds: album.artistIds,
          totalTracks: album.totalTracks,
        );
    if (!mounted) return;
    setState(() => _addedUris.add(album.providerUri));
    _pendingAdded++;
    _snackTimer?.cancel();
    _snackTimer = Timer(const Duration(milliseconds: 500), () {
      if (!mounted) return;
      final n = _pendingAdded;
      _pendingAdded = 0;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: Text(
              n == 1 ? '${album.name} hinzugefügt' : '$n Einträge hinzugefügt',
            ),
            duration: const Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
    });
  }

  Future<void> _addPlaylist(SpotifyPlaylist playlist) async {
    await ref
        .read(contentImporterProvider.notifier)
        .importToGroup(
          groupTitle: playlist.name,
          groupCoverUrl: playlist.imageUrl,
          cards: [
            PendingCard(
              title: playlist.name,
              providerUri: playlist.uri,
              cardType: 'playlist',
              provider: ProviderType.spotify,
              coverUrl: playlist.imageUrl,
              totalTracks: playlist.totalTracks,
            ),
          ],
        );
    if (!mounted) return;
    setState(() => _addedUris.add(playlist.uri));
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text('${playlist.name} hinzugefügt'),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  // ---------------------------------------------------------------------------
  // Album & playlist detail sheets
  // ---------------------------------------------------------------------------

  Future<void> _showAlbumDetail(
    CatalogAlbumResult album,
    CatalogMatch? match,
  ) async {
    if (!mounted) return;
    final isAdded = _addedUris.contains(album.providerUri);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder:
          (ctx) => AlbumDetailSheet(
            album: album,
            catalogMatch: match,
            isAdded: isAdded,
            source: _source,
            onAdd: () {
              Navigator.of(ctx).pop();
              unawaited(_handleAddTap(album, match));
            },
          ),
    );
  }

  Future<void> _showPlaylistDetail(SpotifyPlaylist playlist) async {
    if (!mounted) return;
    final isAdded = _addedUris.contains(playlist.uri);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder:
          (ctx) => PlaylistDetailSheet(
            playlist: playlist,
            isAdded: isAdded,
            onAdd: () {
              Navigator.of(ctx).pop();
              unawaited(_addPlaylist(playlist));
            },
          ),
    );
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    super.build(context); // Required for AutomaticKeepAliveClientMixin
    final catalogAsync = ref.watch(catalogServiceProvider);

    // Series detection for the Spotify tier is no longer needed — the catalog
    // tier above handles series discovery. Only batchSeries (autoAssign mode)
    // is still relevant.

    // In autoAssign mode, offer batch add when all results match one series
    String? batchSeries;
    if (_isAutoAssignMode && _albumResults.isNotEmpty) {
      String? title;
      var allMatch = true;
      for (var i = 0; i < _albumResults.length; i++) {
        if (_addedUris.contains(_albumResults[i].providerUri)) continue;
        final match = i < _catalogMatches.length ? _catalogMatches[i] : null;
        if (match == null) {
          allMatch = false;
          break;
        }
        title ??= match.series.title;
        if (title != match.series.title) {
          allMatch = false;
          break;
        }
      }
      if (allMatch) batchSeries = title;
    }

    final body = Column(
      children: [
        // Auto-assign mode banner (only in standalone mode;
        // AddContentScreen shows its own banner above the tabs)
        if (_isAutoAssignMode && !widget.embedded)
          _AutoAssignBanner(groupTitle: _autoGroup?.title),

        // Search mode toggle (only in general add mode)
        // Playlist search is Spotify-only.
        if (!_isAutoAssignMode &&
            (_source.provider == ProviderType.spotify ||
                _source.provider == ProviderType.appleMusic))
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.screenH,
              vertical: AppSpacing.xs,
            ),
            child: SegmentedButton<_SearchMode>(
              segments: const [
                ButtonSegment(
                  value: _SearchMode.album,
                  icon: Icon(Icons.auto_stories_rounded, size: 18),
                  label: Text('Hörspiele'),
                ),
                ButtonSegment(
                  value: _SearchMode.playlist,
                  icon: Icon(Icons.music_note_rounded, size: 18),
                  label: Text('Musik'),
                ),
              ],
              selected: {_searchMode},
              onSelectionChanged: (s) => _setSearchMode(s.first),
              style: const ButtonStyle(
                textStyle: WidgetStatePropertyAll(
                  TextStyle(
                    fontFamily: 'Nunito',
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                visualDensity: VisualDensity.compact,
              ),
            ),
          ),

        // Search field
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.screenH,
            vertical: AppSpacing.sm,
          ),
          child: TextField(
            controller: _searchController,
            focusNode: _searchFocusNode,
            onChanged: _onSearchChanged,
            decoration: InputDecoration(
              hintText:
                  _searchMode == _SearchMode.playlist
                      ? 'Kinderlieder suchen…'
                      : 'Hörspiel suchen…',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon:
                  _isSearchActive
                      ? IconButton(
                        onPressed: _clearSearch,
                        icon: const Icon(Icons.close_rounded),
                      )
                      : null,
            ),
          ),
        ),

        // Content area: curated grid (default) or two-tier search results.
        Expanded(
          child:
              _isSearchActive
                  ? _buildTwoTierSearch(
                    batchSeries: batchSeries,
                  )
                  : catalogAsync.when(
                    loading:
                        () => const Center(
                          child: CircularProgressIndicator(),
                        ),
                    error: (e, _) => Center(child: Text('Fehler: $e')),
                    data: _buildCuratedGrid,
                  ),
        ),
      ],
    );

    if (widget.embedded) {
      return ColoredBox(
        color: AppColors.parentBackground,
        child: body,
      );
    }

    return Scaffold(
      backgroundColor: AppColors.parentBackground,
      appBar: AppBar(
        backgroundColor: AppColors.parentBackground,
        title: Text(
          _isAutoAssignMode ? 'Folge hinzufügen' : 'Hörspiel hinzufügen',
        ),
      ),
      body: body,
    );
  }

  // ---------------------------------------------------------------------------
  // Curated grid (default view)
  // ---------------------------------------------------------------------------

  Widget _buildCuratedGrid(CatalogService catalog) {
    final isMusicMode = _searchMode == _SearchMode.playlist;
    final series =
        catalog.all
            .where((s) => s.hasCuratedAlbumsFor(_source.provider))
            .where(
              (s) => isMusicMode ? s.isMusic : !s.isMusic,
            )
            .toList()
          ..sort((a, b) => a.title.compareTo(b.title));

    if (series.isEmpty) {
      return const Center(
        child: Text(
          'Noch keine Kacheln im Katalog.',
          style: TextStyle(color: AppColors.textSecondary),
        ),
      );
    }

    return CustomScrollView(
      key: const PageStorageKey('curated-grid'),
      slivers: [
        // Section header
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.screenH,
              AppSpacing.xs,
              AppSpacing.screenH,
              AppSpacing.sm,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isMusicMode ? 'Beliebte Kinderlieder' : 'Beliebte Hörspiele',
                  style: const TextStyle(
                    fontFamily: 'Nunito',
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                const Text(
                  'Tippe auf eine Kachel zum Hinzufügen',
                  style: TextStyle(
                    fontFamily: 'Nunito',
                    fontSize: 13,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),

        // Grid
        SliverLayoutBuilder(
          builder: (context, constraints) {
            final columns = kidGridColumns(constraints.crossAxisExtent);
            return SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  mainAxisSpacing: AppSpacing.md,
                  crossAxisSpacing: AppSpacing.md,
                  childAspectRatio: 0.75,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, index) => CuratedSeriesCard(
                    series: series[index],
                    provider: _source.provider,
                    autoAssignTileId: widget.autoAssignTileId,
                    onSearchSeries: (title) {
                      _searchController.text = title;
                      unawaited(_search(title));
                    },
                  ),
                  childCount: series.length,
                ),
              ),
            );
          },
        ),

        // Bottom padding
        const SliverPadding(padding: EdgeInsets.only(bottom: AppSpacing.xxl)),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Unified search: hero cards + filtered results + collapsible escape hatch
  // ---------------------------------------------------------------------------

  Widget _buildTwoTierSearch({
    String? batchSeries,
  }) {
    // Both modes use the two-tier layout: hero cards (filtered by content
    // type) + album results. In Musik mode on Spotify, playlists are
    // appended below the album results by _buildSearchResults.

    // Nothing to show yet (still debouncing, no catalog hits)
    if (_heroSeries.isEmpty && !_isSearching && !_hasSearched) {
      return const SizedBox.shrink();
    }

    final nonMatching = _nonMatchingIndices;
    final matching = _matchingIndices;

    return CustomScrollView(
      slivers: [
        // Hero cards (catalog matches, capped at 4)
        if (_heroSeries.isNotEmpty)
          SliverList.builder(
            itemCount: _heroSeries.length,
            itemBuilder: (context, index) {
              final series = _heroSeries[index];
              final existingUris = ref.watch(existingItemUrisProvider);
              final providerAlbums = series.albumsForProvider(_source.provider);
              final added =
                  providerAlbums
                      .where((a) => existingUris.contains(a.uri))
                      .length;
              final allAdded =
                  added == providerAlbums.length && providerAlbums.isNotEmpty;
              return CatalogHeroCard(
                series: series,
                provider: _source.provider,
                addedCount: added,
                allAdded: allAdded,
                onTap: () {
                  if (allAdded) {
                    final tiles = ref.read(allTilesProvider).value ?? [];
                    final match = tiles.where(
                      (t) =>
                          t.title.toLowerCase() == series.title.toLowerCase(),
                    );
                    if (match.isNotEmpty) {
                      unawaited(
                        context.push(AppRoutes.parentTileEdit(match.first.id)),
                      );
                      return;
                    }
                  }
                  if (series.hasCuratedAlbumsFor(_source.provider)) {
                    unawaited(
                      context.push(
                        '${AppRoutes.parentCatalogSeries(series.id)}'
                        '?provider=${_source.provider.value}',
                        extra: widget.autoAssignTileId,
                      ),
                    );
                  } else {
                    _searchController.text = series.title;
                    unawaited(_search(series.title));
                  }
                },
              );
            },
          ),

        // Refinement hint when more catalog matches exist than we show
        if (_totalCatalogHits > _maxCatalogResults)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.only(
                left: AppSpacing.screenH,
                right: AppSpacing.screenH,
                top: AppSpacing.sm,
                bottom: AppSpacing.md,
              ),
              child: Text(
                'Suche verfeinern, um weitere Empfehlungen zu sehen.',
                style: TextStyle(
                  fontFamily: 'Nunito',
                  fontSize: 13,
                  color: AppColors.textTertiary,
                ),
              ),
            ),
          ),

        // Batch add banner (auto-assign mode)
        if (batchSeries != null)
          SliverToBoxAdapter(
            child: BatchAddBanner(
              seriesTitle: batchSeries,
              count:
                  _albumResults
                      .where((a) => !_addedUris.contains(a.providerUri))
                      .length,
              onAddAll: () => unawaited(_handleAddAll(batchSeries)),
            ),
          ),

        // Loading indicator while Spotify search is in flight
        if (_isSearching)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(AppSpacing.xl),
              child: Center(child: CircularProgressIndicator()),
            ),
          ),

        // Non-matching Spotify albums (novel content, always visible)
        if (nonMatching.isNotEmpty)
          SliverList.builder(
            itemCount: nonMatching.length,
            itemBuilder: (_, i) => _buildAlbumTile(nonMatching[i]),
          ),

        // Collapsible divider for matching albums
        if (_heroSeries.isNotEmpty && matching.isNotEmpty)
          SliverToBoxAdapter(
            child: CollapsibleDivider(
              matchingCount: matching.length,
              heroes: _heroSeries,
              isExpanded: _isMatchingExpanded,
              onToggle:
                  () => setState(
                    () => _isMatchingExpanded = !_isMatchingExpanded,
                  ),
            ),
          ),

        // Matching albums (collapsed by default, compact styling)
        if (_isMatchingExpanded && matching.isNotEmpty)
          SliverList.builder(
            itemCount: matching.length,
            itemBuilder: (_, i) => _buildAlbumTile(matching[i], compact: true),
          ),

        // Empty state: searched but nothing found anywhere
        if (_hasSearched &&
            !_isSearching &&
            _heroSeries.isEmpty &&
            _albumResults.isEmpty &&
            _playlistResults.isEmpty)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: AppSpacing.screenH,
                vertical: AppSpacing.lg,
              ),
              child: Text(
                'Keine Treffer.',
                style: TextStyle(
                  fontFamily: 'Nunito',
                  fontSize: 14,
                  color: AppColors.textSecondary,
                ),
              ),
            ),
          ),

        // Playlists (Musik mode on Spotify). Shown below album results.
        if (_playlistResults.isNotEmpty) ...[
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                AppSpacing.screenH,
                AppSpacing.lg,
                AppSpacing.screenH,
                AppSpacing.sm,
              ),
              child: Text(
                'Playlists',
                style: TextStyle(
                  fontFamily: 'Nunito',
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textSecondary,
                ),
              ),
            ),
          ),
          SliverList.builder(
            itemCount: _playlistResults.length,
            itemBuilder: (_, index) {
              final playlist = _playlistResults[index];
              return PlaylistResultTile(
                playlist: playlist,
                isAdded: _addedUris.contains(playlist.uri),
                onAdd: () => unawaited(_addPlaylist(playlist)),
                onTap: () => unawaited(_showPlaylistDetail(playlist)),
              );
            },
          ),
        ],

        const SliverPadding(padding: EdgeInsets.only(bottom: AppSpacing.xxl)),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Search results (flat list, used by playlist mode)
  // ---------------------------------------------------------------------------

  Widget _buildAlbumTile(int index, {bool compact = false}) {
    final album = _albumResults[index];
    final match =
        index < _catalogMatches.length ? _catalogMatches[index] : null;
    return SearchResultTile(
      key: ValueKey(album.providerUri),
      album: album,
      isAdded: _addedUris.contains(album.providerUri),
      catalogMatch: match,
      compact: compact,
      onAdd: () => unawaited(_handleAddTap(album, match)),
      onTap: () => unawaited(_showAlbumDetail(album, match)),
    );
  }
}

// ── Search mode ─────────────────────────────────────────────────────────────

enum _SearchMode { album, playlist }

// ── Auto-assign banner ──────────────────────────────────────────────────────

class _AutoAssignBanner extends StatelessWidget {
  const _AutoAssignBanner({this.groupTitle});

  final String? groupTitle;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: AppColors.primary.withValues(alpha: 0.1),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.screenH,
        vertical: AppSpacing.sm,
      ),
      child: Row(
        children: [
          const Icon(
            Icons.layers_rounded,
            size: 16,
            color: AppColors.primary,
          ),
          const SizedBox(width: AppSpacing.xs),
          Expanded(
            child: Text(
              groupTitle != null
                  ? 'Inhalte werden direkt zu »$groupTitle« hinzugefügt'
                  : 'Inhalte werden direkt zur Kachel hinzugefügt',
              style: const TextStyle(
                fontFamily: 'Nunito',
                fontSize: 13,
                color: AppColors.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
