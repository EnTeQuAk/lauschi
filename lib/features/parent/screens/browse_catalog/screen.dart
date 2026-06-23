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
import 'package:lauschi/features/parent/screens/browse_catalog/catalog_search_notifier.dart';
import 'package:lauschi/features/parent/screens/browse_catalog/widgets/album_detail_sheet.dart';
import 'package:lauschi/features/parent/screens/browse_catalog/widgets/batch_add_banner.dart';
import 'package:lauschi/features/parent/screens/browse_catalog/widgets/catalog_helpers.dart';
import 'package:lauschi/features/parent/screens/browse_catalog/widgets/catalog_hero_card.dart';
import 'package:lauschi/features/parent/screens/browse_catalog/widgets/collapsible_divider.dart';
import 'package:lauschi/features/parent/screens/browse_catalog/widgets/curated_series_card.dart';
import 'package:lauschi/features/parent/screens/browse_catalog/widgets/playlist_detail_sheet.dart';
import 'package:lauschi/features/parent/screens/browse_catalog/widgets/playlist_result_tile.dart';
import 'package:lauschi/features/parent/screens/browse_catalog/widgets/search_result_tile.dart';

const _tag = 'BrowseCatalog';

// ── Unified browse + search screen ──────────────────────────────────────────

/// Curated catalog grid with inline search.
///
/// Default view shows the curated series grid with a search bar at the top.
/// When the user types a query, the grid is replaced by live search results.
///
/// Search state (albums, catalog matches, hero series) lives in
/// [CatalogSearch]; the widget owns only UI-local state
/// (text controller, debounce timer, expansion toggle, snackbar batching).
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

  // UI-only state
  bool _isMatchingExpanded = false;
  db.Tile? _autoGroup;

  // Snackbar batching
  Timer? _snackTimer;
  int _pendingAdded = 0;
  final _pendingAssignedCardIds = <String>[];
  String _lastSeriesTitle = '';

  bool get _isSearchActive => _searchController.text.trim().isNotEmpty;
  bool get _isAutoAssignMode => widget.autoAssignTileId != null;

  ProviderType get _provider => widget.catalogSource.provider;
  CatalogSource get _source => widget.catalogSource;

  CatalogSearch get _searchNotifier =>
      ref.read(catalogSearchProvider(_provider).notifier);

  @override
  void initState() {
    super.initState();
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
      _searchNotifier.reset();
      _isMatchingExpanded = false;
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 400), () async {
      await _search(query.trim());
    });
  }

  Future<void> _search(String query) async {
    try {
      await _searchNotifier.search(query, _source);
      final searchState = ref.read(catalogSearchProvider(_provider));
      if (searchState.isMusicMode && _source.provider == ProviderType.spotify) {
        await _searchNotifier.searchPlaylists(
          query,
          ref.read(spotifySessionProvider.notifier),
        );
      }
      if (mounted) setState(() => _isMatchingExpanded = false);
    } on Exception catch (e) {
      Log.error(_tag, 'Search failed', exception: e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Suche fehlgeschlagen'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  void _setSearchMode(CatalogSearchMode mode) {
    final searchState = ref.read(catalogSearchProvider(_provider));
    if (mode == searchState.searchMode) return;
    _searchNotifier.setMode(mode);
    _isMatchingExpanded = false;
    final query = _searchController.text.trim();
    if (query.isNotEmpty) {
      _debounce?.cancel();
      unawaited(_search(query));
    }
  }

  void _clearSearch() {
    _searchController.clear();
    _searchFocusNode.unfocus();
    _searchNotifier.reset();
    _isMatchingExpanded = false;
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
    final existingUris = ref.read(existingItemUrisProvider);
    final searchState = ref.read(catalogSearchProvider(_provider));
    var count = 0;
    for (var i = 0; i < searchState.albums.length; i++) {
      final album = searchState.albums[i];
      if (existingUris.contains(album.providerUri)) continue;
      final match =
          i < searchState.catalogMatches.length
              ? searchState.catalogMatches[i]
              : null;
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
                onPressed: () async {
                  try {
                    final repo = ref.read(tileItemRepositoryProvider);
                    await Future.wait(ids.map(repo.removeFromTile));
                  } on Exception catch (e) {
                    Log.error(_tag, 'Undo failed', exception: e);
                    if (!context.mounted) return;
                    // The mounted check above guards this context use.
                    // ignore: use_build_context_synchronously
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Rückgängig fehlgeschlagen'),
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
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
    final existingUris = ref.read(existingItemUrisProvider);
    final isAdded = existingUris.contains(album.providerUri);
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
    final existingUris = ref.read(existingItemUrisProvider);
    final isAdded = existingUris.contains(playlist.uri);
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
    final searchState = ref.watch(catalogSearchProvider(_provider));
    final existingUris = ref.watch(existingItemUrisProvider);

    final batchSeries =
        _isAutoAssignMode && searchState.albums.isNotEmpty
            ? detectBatchSeries(
              searchState.albums,
              searchState.catalogMatches,
              existingUris,
            )
            : null;

    final body = Column(
      children: [
        // Auto-assign mode banner (only in standalone mode;
        // AddContentScreen shows its own banner above the tabs)
        if (_isAutoAssignMode && !widget.embedded)
          _AutoAssignBanner(groupTitle: _autoGroup?.title),

        // Search mode toggle (only in general add mode)
        // Playlist search is Spotify-only.
        if (!_isAutoAssignMode &&
            (_provider == ProviderType.spotify ||
                _provider == ProviderType.appleMusic))
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.screenH,
              vertical: AppSpacing.xs,
            ),
            child: SegmentedButton<CatalogSearchMode>(
              segments: const [
                ButtonSegment(
                  value: CatalogSearchMode.album,
                  icon: Icon(Icons.auto_stories_rounded, size: 18),
                  label: Text('Hörspiele'),
                ),
                ButtonSegment(
                  value: CatalogSearchMode.playlist,
                  icon: Icon(Icons.music_note_rounded, size: 18),
                  label: Text('Musik'),
                ),
              ],
              selected: {searchState.searchMode},
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
                  searchState.isMusicMode
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
                    searchState: searchState,
                    existingUris: existingUris,
                    batchSeries: batchSeries,
                  )
                  : catalogAsync.when(
                    loading:
                        () => const Center(
                          child: CircularProgressIndicator(),
                        ),
                    error: (e, _) => Center(child: Text('Fehler: $e')),
                    data:
                        (catalog) => _buildCuratedGrid(
                          catalog,
                          isMusicMode: searchState.isMusicMode,
                        ),
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

  Widget _buildCuratedGrid(
    CatalogService catalog, {
    required bool isMusicMode,
  }) {
    final series =
        catalog.all
            .where((s) => s.hasCuratedAlbumsFor(_provider))
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
                    provider: _provider,
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
    required CatalogSearchState searchState,
    required Set<String> existingUris,
    String? batchSeries,
  }) {
    if (searchState.heroSeries.isEmpty &&
        !searchState.isSearching &&
        !searchState.hasSearched) {
      return const SizedBox.shrink();
    }

    final partition = partitionByHeroSeries(
      searchState.catalogMatches,
      searchState.heroSeries.map((h) => h.id).toSet(),
      searchState.albums.length,
    );
    final matching = partition.matching;
    final nonMatching = partition.nonMatching;

    return CustomScrollView(
      slivers: [
        // Hero cards (catalog matches, capped at 4)
        if (searchState.heroSeries.isNotEmpty)
          SliverList.builder(
            itemCount: searchState.heroSeries.length,
            itemBuilder: (context, index) {
              final series = searchState.heroSeries[index];
              final providerAlbums = series.albumsForProvider(_provider);
              final added =
                  providerAlbums
                      .where((a) => existingUris.contains(a.uri))
                      .length;
              final allAdded =
                  added == providerAlbums.length && providerAlbums.isNotEmpty;
              return CatalogHeroCard(
                series: series,
                provider: _provider,
                addedCount: added,
                allAdded: allAdded,
                onTap: () {
                  if (allAdded) {
                    final tilesAsync = ref.read(allTilesProvider);
                    if (tilesAsync case AsyncData(:final value)) {
                      final match = value.where(
                        (t) =>
                            t.title.toLowerCase() == series.title.toLowerCase(),
                      );
                      if (match.isNotEmpty) {
                        unawaited(
                          context.push(
                            AppRoutes.parentTileEdit(match.first.id),
                          ),
                        );
                        return;
                      }
                    }
                  }
                  if (series.hasCuratedAlbumsFor(_provider)) {
                    unawaited(
                      context.push(
                        '${AppRoutes.parentCatalogSeries(series.id)}'
                        '?provider=${_provider.value}',
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
        if (searchState.totalCatalogHits > maxCatalogResults)
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
                  searchState.albums
                      .where((a) => !existingUris.contains(a.providerUri))
                      .length,
              onAddAll: () => unawaited(_handleAddAll(batchSeries)),
            ),
          ),

        // Loading indicator while search is in flight
        if (searchState.isSearching)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(AppSpacing.xl),
              child: Center(child: CircularProgressIndicator()),
            ),
          ),

        // Non-matching albums (novel content, always visible)
        if (nonMatching.isNotEmpty)
          SliverList.builder(
            itemCount: nonMatching.length,
            itemBuilder:
                (_, i) => _buildAlbumTile(
                  nonMatching[i],
                  searchState: searchState,
                  existingUris: existingUris,
                ),
          ),

        // Collapsible divider for matching albums
        if (searchState.heroSeries.isNotEmpty && matching.isNotEmpty)
          SliverToBoxAdapter(
            child: CollapsibleDivider(
              matchingCount: matching.length,
              heroes: searchState.heroSeries,
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
            itemBuilder:
                (_, i) => _buildAlbumTile(
                  matching[i],
                  searchState: searchState,
                  existingUris: existingUris,
                  compact: true,
                ),
          ),

        // Empty state: searched but nothing found anywhere
        if (searchState.hasSearched &&
            !searchState.isSearching &&
            searchState.heroSeries.isEmpty &&
            searchState.albums.isEmpty &&
            searchState.playlists.isEmpty)
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
        if (searchState.playlists.isNotEmpty) ...[
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
            itemCount: searchState.playlists.length,
            itemBuilder: (_, index) {
              final playlist = searchState.playlists[index];
              return PlaylistResultTile(
                playlist: playlist,
                isAdded: existingUris.contains(playlist.uri),
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
  // Album tile builder
  // ---------------------------------------------------------------------------

  Widget _buildAlbumTile(
    int index, {
    required CatalogSearchState searchState,
    required Set<String> existingUris,
    bool compact = false,
  }) {
    final album = searchState.albums[index];
    final match =
        index < searchState.catalogMatches.length
            ? searchState.catalogMatches[index]
            : null;
    return SearchResultTile(
      key: ValueKey(album.providerUri),
      album: album,
      isAdded: existingUris.contains(album.providerUri),
      catalogMatch: match,
      compact: compact,
      onAdd: () => unawaited(_handleAddTap(album, match)),
      onTap: () => unawaited(_showAlbumDetail(album, match)),
    );
  }
}

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
