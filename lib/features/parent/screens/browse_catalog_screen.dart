import 'dart:async' show Timer, unawaited;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lauschi/core/catalog/catalog_service.dart';
import 'package:lauschi/core/database/app_database.dart' as db;
import 'package:lauschi/core/database/tile_item_repository.dart';
import 'package:lauschi/core/database/content_importer.dart';
import 'package:lauschi/core/database/tile_repository.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/router/app_router.dart';
import 'package:lauschi/core/spotify/spotify_api.dart';
import 'package:lauschi/core/spotify/spotify_auth_provider.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/player/player_provider.dart';

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
class BrowseCatalogScreen extends ConsumerStatefulWidget {
  const BrowseCatalogScreen({super.key, this.autoAssignTileId});

  final String? autoAssignTileId;

  @override
  ConsumerState<BrowseCatalogScreen> createState() =>
      _BrowseCatalogScreenState();
}

class _BrowseCatalogScreenState extends ConsumerState<BrowseCatalogScreen> {
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();
  Timer? _debounce;

  // Search state
  _SearchMode _searchMode = _SearchMode.album;
  List<SpotifyAlbum> _albumResults = [];
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
      if (_searchMode == _SearchMode.playlist) {
        await _searchPlaylists(query);
      } else {
        await _searchAlbums(query);
      }
    } on Exception catch (e) {
      Log.error(_tag, 'Search failed', exception: e);
      if (mounted) setState(() => _isSearching = false);
    }
  }

  Future<void> _searchAlbums(String query) async {
    final gen = ++_searchGeneration;
    final result = await ref.read(spotifyApiProvider).searchAlbums(query);
    if (!mounted || gen != _searchGeneration) return;
    final catalog = ref.read(catalogServiceProvider).value;
    final matches =
        catalog != null
            ? result.albums
                .map(
                  (a) => catalog.match(a.name, albumArtistIds: a.artistIds),
                )
                .toList()
            : List<CatalogMatch?>.filled(result.albums.length, null);
    final catalogHits = matches.whereType<CatalogMatch>().length;
    Log.info(
      _tag,
      'Search',
      data: {
        'query': query,
        'results': '${result.albums.length}',
        'catalogHits': '$catalogHits',
      },
    );
    // Hero series from catalog search (instant, local)
    final allCatalogHits =
        catalog?.search(query).where((s) => s.hasCuratedAlbums).toList() ?? [];
    setState(() {
      _albumResults = result.albums;
      _playlistResults = [];
      _catalogMatches = matches;
      _heroSeries = allCatalogHits.take(_maxCatalogResults).toList();
      _totalCatalogHits = allCatalogHits.length;
      _isMatchingExpanded = false;
      _isSearching = false;
      _hasSearched = true;
    });
  }

  Future<void> _searchPlaylists(String query) async {
    final gen = ++_searchGeneration;
    final result = await ref.read(spotifyApiProvider).searchPlaylists(query);
    if (!mounted || gen != _searchGeneration) return;
    Log.info(
      _tag,
      'Search (playlists)',
      data: {'query': query, 'results': '${result.playlists.length}'},
    );
    setState(() {
      _playlistResults = result.playlists;
      _albumResults = [];
      _catalogMatches = [];
      _isSearching = false;
      _hasSearched = true;
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

  Future<void> _handleAddTap(SpotifyAlbum album, CatalogMatch? match) async {
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
      if (_addedUris.contains(album.uri)) continue;
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
            content: Text('$count Folgen zu »$seriesTitle« hinzugefügt'),
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
    SpotifyAlbum album,
    String groupId,
    CatalogMatch? match, {
    bool showUndo = false,
    bool silent = false,
  }) async {
    final cardId = await ref
        .read(tileItemRepositoryProvider)
        .insertIfAbsent(
          title: album.name,
          providerUri: album.uri,
          cardType: 'album',
          coverUrl: album.imageUrl,
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
    setState(() => _addedUris.add(album.uri));

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
                : '${ids.length} Folgen zu »$_lastSeriesTitle« hinzugefügt';
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
            n == 1 ? '${album.name} hinzugefügt' : '$n Folgen hinzugefügt';
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

  Future<void> _addOnly(SpotifyAlbum album) async {
    await ref
        .read(tileItemRepositoryProvider)
        .insertIfAbsent(
          title: album.name,
          providerUri: album.uri,
          cardType: 'album',
          coverUrl: album.imageUrl,
          spotifyArtistIds: album.artistIds,
          totalTracks: album.totalTracks,
        );
    if (!mounted) return;
    setState(() => _addedUris.add(album.uri));
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
              n == 1 ? '${album.name} hinzugefügt' : '$n Folgen hinzugefügt',
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
              provider: 'spotify',
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
    SpotifyAlbum album,
    CatalogMatch? match,
  ) async {
    if (!mounted) return;
    final isAdded = _addedUris.contains(album.uri);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder:
          (ctx) => _AlbumDetailSheet(
            album: album,
            catalogMatch: match,
            isAdded: isAdded,
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
          (ctx) => _PlaylistDetailSheet(
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
    final authState = ref.watch(spotifyAuthProvider);
    final catalogAsync = ref.watch(catalogServiceProvider);

    // Spotify not connected — show connection prompt
    if (authState is! AuthAuthenticated) {
      return _SpotifyNotConnected(
        isAutoAssignMode: _isAutoAssignMode,
      );
    }

    // Series detection for the Spotify tier is no longer needed — the catalog
    // tier above handles series discovery. Only batchSeries (autoAssign mode)
    // is still relevant.

    // In autoAssign mode, offer batch add when all results match one series
    String? batchSeries;
    if (_isAutoAssignMode && _albumResults.isNotEmpty) {
      String? title;
      var allMatch = true;
      for (var i = 0; i < _albumResults.length; i++) {
        if (_addedUris.contains(_albumResults[i].uri)) continue;
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

    return Scaffold(
      backgroundColor: AppColors.parentBackground,
      appBar: AppBar(
        backgroundColor: AppColors.parentBackground,
        title: Text(
          _isAutoAssignMode ? 'Folge hinzufügen' : 'Hörspiel hinzufügen',
        ),
      ),
      body: Column(
        children: [
          // Auto-assign mode banner
          if (_isAutoAssignMode)
            _AutoAssignBanner(groupTitle: _autoGroup?.title),

          // Search mode toggle (only in general add mode)
          if (!_isAutoAssignMode)
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
                        ? 'Playlists auf Spotify suchen…'
                        : 'Hörspiel auf Spotify suchen…',
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
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Curated grid (default view)
  // ---------------------------------------------------------------------------

  Widget _buildCuratedGrid(CatalogService catalog) {
    final series =
        catalog.all.where((s) => s.hasCuratedAlbums).toList()
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
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              AppSpacing.screenH,
              AppSpacing.xs,
              AppSpacing.screenH,
              AppSpacing.sm,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Beliebte Hörspiele',
                  style: TextStyle(
                    fontFamily: 'Nunito',
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
                SizedBox(height: 2),
                Text(
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
                  (context, index) => _CuratedSeriesCard(series: series[index]),
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
    // Playlist mode uses the legacy flat list
    if (_searchMode == _SearchMode.playlist) {
      return _buildSearchResults(batchSeries: batchSeries);
    }

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
              final added =
                  series.albums
                      .where(
                        (a) => existingUris.contains(
                          'spotify:album:${a.spotifyId}',
                        ),
                      )
                      .length;
              final allAdded = added == series.albums.length;
              return _HeroCard(
                series: series,
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
                  unawaited(
                    context.push(AppRoutes.parentCatalogSeries(series.id)),
                  );
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
            child: _BatchAddBanner(
              seriesTitle: batchSeries,
              count:
                  _albumResults
                      .where((a) => !_addedUris.contains(a.uri))
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
            child: _CollapsibleDivider(
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
            _albumResults.isEmpty)
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

        const SliverPadding(padding: EdgeInsets.only(bottom: AppSpacing.xxl)),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Search results (legacy, used by playlist mode)
  // ---------------------------------------------------------------------------

  Widget _buildSearchResults({
    String? batchSeries,
  }) {
    final headers = <Widget>[
      if (batchSeries != null)
        _BatchAddBanner(
          seriesTitle: batchSeries,
          count: _albumResults.where((a) => !_addedUris.contains(a.uri)).length,
          onAddAll: () => unawaited(_handleAddAll(batchSeries)),
        ),
    ];

    if (_isSearching) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_searchMode == _SearchMode.playlist) {
      if (_playlistResults.isEmpty && _hasSearched) {
        return const Center(
          child: Text(
            'Keine Ergebnisse.',
            style: TextStyle(
              fontFamily: 'Nunito',
              fontSize: 15,
              color: AppColors.textSecondary,
            ),
          ),
        );
      }
      return ListView.builder(
        itemCount: _playlistResults.length,
        padding: const EdgeInsets.only(bottom: AppSpacing.xxl),
        itemBuilder: (context, index) {
          final playlist = _playlistResults[index];
          return _PlaylistResultTile(
            playlist: playlist,
            isAdded: _addedUris.contains(playlist.uri),
            onAdd: () => unawaited(_addPlaylist(playlist)),
            onTap: () => unawaited(_showPlaylistDetail(playlist)),
          );
        },
      );
    }

    if (_albumResults.isEmpty && _hasSearched) {
      return const Center(
        child: Text(
          'Keine Ergebnisse.',
          style: TextStyle(
            fontFamily: 'Nunito',
            fontSize: 15,
            color: AppColors.textSecondary,
          ),
        ),
      );
    }

    if (headers.isEmpty) {
      return ListView.builder(
        itemCount: _albumResults.length,
        padding: const EdgeInsets.only(bottom: AppSpacing.xxl),
        cacheExtent: 500,
        itemBuilder: (context, index) => _buildAlbumTile(index),
      );
    }

    return ListView.builder(
      itemCount: headers.length + _albumResults.length,
      padding: const EdgeInsets.only(bottom: AppSpacing.xxl),
      cacheExtent: 500,
      itemBuilder: (context, index) {
        if (index < headers.length) return headers[index];
        return _buildAlbumTile(index - headers.length);
      },
    );
  }

  Widget _buildAlbumTile(int index, {bool compact = false}) {
    final album = _albumResults[index];
    final match =
        index < _catalogMatches.length ? _catalogMatches[index] : null;
    return _SearchResultTile(
      key: ValueKey(album.uri),
      album: album,
      isAdded: _addedUris.contains(album.uri),
      catalogMatch: match,
      compact: compact,
      onAdd: () => unawaited(_handleAddTap(album, match)),
      onTap: () => unawaited(_showAlbumDetail(album, match)),
    );
  }
}

// ── Search mode ─────────────────────────────────────────────────────────────

enum _SearchMode { album, playlist }

// ── Spotify not connected ───────────────────────────────────────────────────

class _SpotifyNotConnected extends ConsumerWidget {
  const _SpotifyNotConnected({required this.isAutoAssignMode});

  final bool isAutoAssignMode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      backgroundColor: AppColors.parentBackground,
      appBar: AppBar(
        backgroundColor: AppColors.parentBackground,
        title: Text(
          isAutoAssignMode ? 'Folge hinzufügen' : 'Hörspiel hinzufügen',
        ),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.screenH),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.music_off_rounded,
                size: 48,
                color: AppColors.textSecondary,
              ),
              const SizedBox(height: AppSpacing.md),
              const Text(
                'Spotify nicht verbunden',
                style: TextStyle(
                  fontFamily: 'Nunito',
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              const Text(
                'Verbinde Spotify in den Einstellungen, um '
                'Hörspiele und Musik hinzuzufügen.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'Nunito',
                  fontSize: 14,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              FilledButton.icon(
                onPressed: () => context.push(AppRoutes.parentSettings),
                icon: const Icon(Icons.settings_rounded),
                label: const Text('Einstellungen'),
              ),
            ],
          ),
        ),
      ),
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
                  ? 'Folgen werden direkt zu »$groupTitle« hinzugefügt'
                  : 'Folgen werden direkt zur Kachel hinzugefügt',
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

// ── Curated series card ─────────────────────────────────────────────────────

class _CuratedSeriesCard extends ConsumerWidget {
  const _CuratedSeriesCard({required this.series});

  final CatalogSeries series;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final coverMap = ref.watch(_seriesCoverMapProvider).value ?? {};
    final existingUris = ref.watch(existingItemUrisProvider);
    final firstAlbumId =
        series.albums.isNotEmpty ? series.albums.first.spotifyId : null;
    // Curated cover_url from YAML takes priority over album art.
    final coverUrl =
        series.coverUrl ??
        (firstAlbumId != null ? coverMap[firstAlbumId] : null);

    final total = series.albums.length;
    final added =
        series.albums
            .where((a) => existingUris.contains('spotify:album:${a.spotifyId}'))
            .length;
    final allAdded = added == total && total > 0;

    return GestureDetector(
      onTap: () {
        if (allAdded) {
          // All episodes already added — find the group and navigate there.
          final groups = ref.read(allTilesProvider).value ?? [];
          final matchingGroup = groups.where(
            (g) => g.title.toLowerCase() == series.title.toLowerCase(),
          );
          if (matchingGroup.isNotEmpty) {
            unawaited(
              context.push(
                AppRoutes.parentTileEdit(matchingGroup.first.id),
              ),
            );
            return;
          }
        }
        unawaited(context.push(AppRoutes.parentCatalogSeries(series.id)));
      },
      child: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: ClipRRect(
                    borderRadius: const BorderRadius.all(AppRadius.card),
                    child:
                        coverUrl != null
                            ? CachedNetworkImage(
                              imageUrl: coverUrl,
                              fit: BoxFit.cover,
                              width: double.infinity,
                              height: double.infinity,
                              placeholder:
                                  (_, _) => _Placeholder(title: series.title),
                              errorWidget:
                                  (_, _, _) =>
                                      _Placeholder(title: series.title),
                            )
                            : _Placeholder(title: series.title),
                  ),
                ),
                // Badge: check when fully added, count when partially added
                if (added > 0)
                  Positioned(
                    right: 4,
                    top: 4,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: allAdded ? AppColors.success : AppColors.primary,
                        borderRadius: const BorderRadius.all(AppRadius.pill),
                      ),
                      child:
                          allAdded
                              ? const Icon(
                                Icons.check_rounded,
                                size: 12,
                                color: Colors.white,
                              )
                              : Text(
                                '$added/$total',
                                style: const TextStyle(
                                  fontFamily: 'Nunito',
                                  fontSize: 9,
                                  fontWeight: FontWeight.w800,
                                  color: Colors.white,
                                ),
                              ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            series.title,
            style: const TextStyle(
              fontFamily: 'Nunito',
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
          Text(
            allAdded
                ? '✓ Hinzugefügt'
                : added > 0
                ? '$added von $total Folgen'
                : '$total Folgen',
            style: TextStyle(
              fontFamily: 'Nunito',
              fontSize: 10,
              color: allAdded ? AppColors.success : AppColors.textSecondary,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

// ── Series detail ───────────────────────────────────────────────────────────

/// Shows episodes for a catalog series. Parents can select and add them as
/// cards in one batch.
class CatalogSeriesDetailScreen extends ConsumerStatefulWidget {
  const CatalogSeriesDetailScreen({required this.seriesId, super.key});

  final String seriesId;

  @override
  ConsumerState<CatalogSeriesDetailScreen> createState() =>
      _CatalogSeriesDetailScreenState();
}

class _CatalogSeriesDetailScreenState
    extends ConsumerState<CatalogSeriesDetailScreen> {
  final _selected = <String>{};
  bool _selectAll = true;
  bool _isAdding = false;

  CatalogSeries? _findSeries(CatalogService catalog) {
    final matches = catalog.all.where((s) => s.id == widget.seriesId);
    return matches.isEmpty ? null : matches.first;
  }

  void _toggleSelectAll(CatalogSeries series) {
    setState(() {
      _selectAll = !_selectAll;
      if (_selectAll) {
        final uris = ref.read(existingItemUrisProvider);
        _selected.addAll(
          series.albums
              .where(
                (a) => !uris.contains('spotify:album:${a.spotifyId}'),
              )
              .map((a) => a.spotifyId),
        );
      } else {
        _selected.clear();
      }
    });
  }

  Future<void> _addSelected(CatalogSeries series) async {
    if (_selected.isEmpty) return;

    setState(() => _isAdding = true);

    final api = ref.read(spotifyApiProvider);
    if (!api.hasToken) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Spotify nicht verbunden')),
        );
        setState(() => _isAdding = false);
      }
      return;
    }

    // Progress state for the modal.
    final progressNotifier = ValueNotifier<(int, int)>((0, _selected.length));
    final statusNotifier = ValueNotifier<String>(
      'Lade ${series.title}…',
    );

    if (mounted) {
      unawaited(
        showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder:
              (_) => _AddProgressDialog(
                progress: progressNotifier,
                status: statusNotifier,
              ),
        ),
      );
    }

    try {
      final albumIds = _selected.toList();
      final total = albumIds.length;

      // Spotify allows max 20 IDs per request — batch in chunks.
      final albums = <SpotifyAlbum>[];
      for (var i = 0; i < albumIds.length; i += 20) {
        final chunk = albumIds.sublist(
          i,
          (i + 20).clamp(0, albumIds.length),
        );
        albums.addAll(await api.getAlbums(chunk));
        progressNotifier.value = (albums.length, total);
      }

      statusNotifier.value = 'Speichere ${series.title}…';

      final cards = <PendingCard>[];
      for (final album in albums) {
        final catalogAlbum =
            series.albums.where((a) => a.spotifyId == album.id).firstOrNull;

        cards.add(
          PendingCard(
            title: album.name,
            providerUri: album.uri,
            cardType: 'album',
            provider: 'spotify',
            coverUrl: album.imageUrl,
            episodeNumber: catalogAlbum?.episode,
            spotifyArtistIds: album.artistIds,
            totalTracks: album.totalTracks,
          ),
        );
      }

      final importer = ref.read(contentImporterProvider.notifier);
      final firstAlbum = albums.isNotEmpty ? albums.first : null;
      final result = await importer.importToGroup(
        groupTitle: series.title,
        groupCoverUrl: firstAlbum?.imageUrl,
        cards: cards,
      );

      Log.info(
        _tag,
        'Added ${result.added} cards to ${series.title}',
        data: {'seriesId': series.id, 'count': result.added},
      );

      if (mounted) {
        Navigator.of(context).pop(); // dismiss dialog
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${result.added} Folgen zu ${series.title} hinzugefügt',
            ),
          ),
        );
        setState(() {
          _selected.clear();
          _isAdding = false;
        });
      }
    } on Exception catch (e) {
      Log.error(_tag, 'Failed to add cards', exception: e);
      if (mounted) {
        Navigator.of(context).pop(); // dismiss dialog
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Fehler: $e')),
        );
        setState(() => _isAdding = false);
      }
    } finally {
      progressNotifier.dispose();
      statusNotifier.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final existingUris = ref.watch(existingItemUrisProvider);
    final cardsLoaded = ref.watch(allTileItemsProvider).hasValue;
    final catalogAsync = ref.watch(catalogServiceProvider);

    return catalogAsync.when(
      loading:
          () => const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          ),
      error:
          (e, _) => Scaffold(
            body: Center(child: Text('Fehler: $e')),
          ),
      data: (catalog) {
        final series = _findSeries(catalog);
        if (series == null) {
          return Scaffold(
            appBar: AppBar(title: const Text('Nicht gefunden')),
            body: const Center(child: Text('Kachel nicht gefunden.')),
          );
        }

        final albums =
            series.albums.toList()..sort(
              (a, b) => (a.episode ?? 999999).compareTo(b.episode ?? 999999),
            );

        final coverKey = albums.map((a) => a.spotifyId).join(',');
        final coverMap = ref.watch(_albumCoversProvider(coverKey)).value ?? {};

        if (_selected.isEmpty && _selectAll && cardsLoaded) {
          for (final album in albums) {
            if (!existingUris.contains(
              'spotify:album:${album.spotifyId}',
            )) {
              _selected.add(album.spotifyId);
            }
          }
        }

        final selectableCount =
            albums
                .where(
                  (a) =>
                      !existingUris.contains(
                        'spotify:album:${a.spotifyId}',
                      ),
                )
                .length;

        return Scaffold(
          backgroundColor: AppColors.parentBackground,
          appBar: AppBar(
            backgroundColor: AppColors.parentBackground,
            title: Text(series.title),
            actions: [
              if (selectableCount > 0)
                TextButton(
                  onPressed: () => _toggleSelectAll(series),
                  child: Text(
                    _selectAll ? 'Keine' : 'Alle',
                    style: const TextStyle(fontFamily: 'Nunito'),
                  ),
                ),
            ],
          ),
          body: ListView.builder(
            itemCount: albums.length,
            itemBuilder: (context, index) {
              final album = albums[index];
              final uri = 'spotify:album:${album.spotifyId}';
              final alreadyAdded = existingUris.contains(uri);
              final isSelected = _selected.contains(album.spotifyId);

              return _AlbumTile(
                album: album,
                coverUrl: coverMap[album.spotifyId],
                alreadyAdded: alreadyAdded,
                isSelected: isSelected,
                onChanged: () {
                  setState(() {
                    if (isSelected) {
                      _selected.remove(album.spotifyId);
                    } else {
                      _selected.add(album.spotifyId);
                    }
                  });
                },
              );
            },
          ),
          bottomNavigationBar:
              _selected.isNotEmpty
                  ? SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpacing.md),
                      child: FilledButton.icon(
                        onPressed:
                            _isAdding ? null : () => _addSelected(series),
                        icon:
                            _isAdding
                                ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                                : const Icon(Icons.add_rounded),
                        label: Text(
                          '${_selected.length} Folgen hinzufügen',
                          style: const TextStyle(fontFamily: 'Nunito'),
                        ),
                      ),
                    ),
                  )
                  : null,
        );
      },
    );
  }
}

// ── Album tile (series detail) ──────────────────────────────────────────────

class _AlbumTile extends StatelessWidget {
  const _AlbumTile({
    required this.album,
    required this.alreadyAdded,
    required this.isSelected,
    required this.onChanged,
    this.coverUrl,
  });

  final CatalogAlbum album;
  final bool alreadyAdded;
  final bool isSelected;
  final VoidCallback onChanged;
  final String? coverUrl;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 32,
            height: 32,
            child: Center(
              child:
                  alreadyAdded
                      ? const Icon(Icons.check_circle, color: AppColors.success)
                      : Checkbox(
                        value: isSelected,
                        onChanged: (_) => onChanged(),
                      ),
            ),
          ),
          const SizedBox(width: 8),
          ClipRRect(
            borderRadius: const BorderRadius.all(Radius.circular(4)),
            child:
                coverUrl != null
                    ? CachedNetworkImage(
                      imageUrl: coverUrl!,
                      width: 44,
                      height: 44,
                      fit: BoxFit.cover,
                    )
                    : const SizedBox(
                      width: 44,
                      height: 44,
                      child: ColoredBox(
                        color: AppColors.surfaceDim,
                        child: Icon(
                          Icons.album_rounded,
                          size: 20,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ),
          ),
        ],
      ),
      title: Text(
        album.title,
        style: TextStyle(
          fontFamily: 'Nunito',
          fontSize: 14,
          color: alreadyAdded ? AppColors.textSecondary : AppColors.textPrimary,
        ),
      ),
      subtitle:
          album.episode != null
              ? Text(
                'Folge ${album.episode}',
                style: const TextStyle(
                  fontFamily: 'Nunito',
                  fontSize: 12,
                  color: AppColors.textSecondary,
                ),
              )
              : null,
      enabled: !alreadyAdded,
      onTap: alreadyAdded ? null : onChanged,
    );
  }
}

class _HeroCard extends ConsumerWidget {
  const _HeroCard({
    required this.series,
    required this.addedCount,
    required this.allAdded,
    required this.onTap,
  });

  final CatalogSeries series;
  final int addedCount;
  final bool allAdded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final coverMap = ref.watch(_seriesCoverMapProvider).value ?? {};
    final firstAlbumId =
        series.albums.isNotEmpty ? series.albums.first.spotifyId : null;
    final coverUrl =
        series.coverUrl ??
        (firstAlbumId != null ? coverMap[firstAlbumId] : null);
    final total = series.albums.length;

    return InkWell(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(
          horizontal: AppSpacing.screenH,
          vertical: 4,
        ),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: const BorderRadius.all(Radius.circular(12)),
          boxShadow: const [
            BoxShadow(
              color: Color(0x0A000000),
              blurRadius: 6,
              offset: Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: const BorderRadius.all(Radius.circular(8)),
              child: SizedBox(
                width: 52,
                height: 52,
                child:
                    coverUrl != null
                        ? CachedNetworkImage(
                          imageUrl: coverUrl,
                          fit: BoxFit.cover,
                          memCacheWidth: 104,
                        )
                        : _Placeholder(title: series.title),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.auto_awesome_rounded,
                        size: 14,
                        color: AppColors.primary,
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          series.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: 'Nunito',
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    allAdded
                        ? '✓ Alle $total Folgen hinzugefügt'
                        : '$total Folgen · Alles sortiert',
                    style: TextStyle(
                      fontFamily: 'Nunito',
                      fontSize: 12,
                      color:
                          allAdded
                              ? AppColors.success
                              : AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              allAdded
                  ? Icons.check_circle_rounded
                  : Icons.chevron_right_rounded,
              color: allAdded ? AppColors.success : AppColors.textSecondary,
              size: 20,
            ),
          ],
        ),
      ),
    );
  }
}

// ── Collapsible divider (escape hatch for matching albums) ──────────────────

class _CollapsibleDivider extends StatelessWidget {
  const _CollapsibleDivider({
    required this.matchingCount,
    required this.heroes,
    required this.isExpanded,
    required this.onToggle,
  });

  final int matchingCount;
  final List<CatalogSeries> heroes;
  final bool isExpanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final label =
        heroes.length == 1
            ? '$matchingCount Einzelfolgen · In ${heroes.first.title} enthalten'
            : '$matchingCount Einzelfolgen · In den Empfehlungen enthalten';

    return Semantics(
      button: true,
      expanded: isExpanded,
      onTapHint:
          isExpanded
              ? 'Einzelne Folgen ausblenden'
              : 'Einzelne Folgen anzeigen',
      child: InkWell(
        onTap: onToggle,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.screenH,
            vertical: AppSpacing.md,
          ),
          child: Column(
            children: [
              const Divider(height: 1),
              const SizedBox(height: AppSpacing.sm),
              Text(
                label,
                style: const TextStyle(
                  fontFamily: 'Nunito',
                  fontSize: 12,
                  color: AppColors.textTertiary,
                ),
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    isExpanded
                        ? 'Einzelne Folgen ausblenden'
                        : 'Einzelne Folgen anzeigen',
                    style: const TextStyle(
                      fontFamily: 'Nunito',
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppColors.primary,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    isExpanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 18,
                    color: AppColors.primary,
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              const Divider(height: 1),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Batch-add banner ────────────────────────────────────────────────────────

class _BatchAddBanner extends StatelessWidget {
  const _BatchAddBanner({
    required this.seriesTitle,
    required this.count,
    required this.onAddAll,
  });

  final String seriesTitle;
  final int count;
  final VoidCallback onAddAll;

  @override
  Widget build(BuildContext context) {
    if (count == 0) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.symmetric(
        horizontal: AppSpacing.screenH,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.08),
        borderRadius: const BorderRadius.all(AppRadius.card),
      ),
      child: ListTile(
        dense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.xs,
        ),
        leading: const Icon(
          Icons.layers_rounded,
          color: AppColors.primary,
          size: 20,
        ),
        title: Text(
          count == 1
              ? 'Zur Kachel »$seriesTitle« hinzufügen'
              : 'Alle $count Folgen zu »$seriesTitle« hinzufügen',
          style: const TextStyle(
            fontFamily: 'Nunito',
            fontWeight: FontWeight.w700,
            fontSize: 14,
            color: AppColors.primary,
          ),
        ),
        trailing: FilledButton(
          onPressed: onAddAll,
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.xs,
            ),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: Text(count == 1 ? 'Hinzufügen' : 'Alle hinzufügen'),
        ),
      ),
    );
  }
}

// ── Search result tile ──────────────────────────────────────────────────────

class _SearchResultTile extends StatelessWidget {
  const _SearchResultTile({
    super.key,
    required this.album,
    required this.isAdded,
    required this.onAdd,
    required this.onTap,
    this.catalogMatch,
    this.compact = false,
  });

  final SpotifyAlbum album;
  final bool isAdded;
  final CatalogMatch? catalogMatch;
  final VoidCallback onAdd;
  final VoidCallback onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final coverSize = compact ? 44.0 : 56.0;
    final cover = ClipRRect(
      borderRadius: const BorderRadius.all(Radius.circular(6)),
      child: SizedBox(
        width: coverSize,
        height: coverSize,
        child:
            album.imageUrl != null
                ? CachedNetworkImage(
                  imageUrl: album.imageUrl!,
                  fit: BoxFit.cover,
                  memCacheWidth: compact ? 88 : 112,
                )
                : const ColoredBox(
                  color: AppColors.surfaceDim,
                  child: Icon(Icons.music_note_rounded),
                ),
      ),
    );

    // Already-added cards can still be tapped to reassign to current group.
    final trailing = IconButton(
      onPressed: onAdd,
      tooltip: isAdded ? 'Erneut zuweisen' : 'Hinzufügen',
      icon: Icon(isAdded ? Icons.check_rounded : Icons.add_rounded),
      color: isAdded ? AppColors.success : AppColors.primary,
    );

    // Compact mode: hide catalog match chip (the divider already explains it)
    final showCatalogChip = catalogMatch != null && !compact;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: 16,
          vertical: compact ? 4 : 8,
        ),
        child: Row(
          children: [
            cover,
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    album.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'Nunito',
                      fontWeight: compact ? FontWeight.w500 : FontWeight.w600,
                      fontSize: compact ? 14 : 15,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${album.artistNames} · ${album.totalTracks} Titel',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'Nunito',
                      fontSize: 13,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  if (showCatalogChip) ...[
                    const SizedBox(height: 2),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.layers_rounded,
                          size: 11,
                          color: AppColors.primary,
                        ),
                        const SizedBox(width: 3),
                        Flexible(
                          child: Text(
                            catalogMatch!.episodeNumber != null
                                ? '${catalogMatch!.series.title} · '
                                    'Folge ${catalogMatch!.episodeNumber}'
                                : catalogMatch!.series.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontFamily: 'Nunito',
                              fontSize: 11,
                              color: AppColors.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            trailing,
          ],
        ),
      ),
    );
  }
}

// ── Playlist result tile ────────────────────────────────────────────────────

class _PlaylistResultTile extends StatelessWidget {
  const _PlaylistResultTile({
    required this.playlist,
    required this.isAdded,
    required this.onAdd,
    required this.onTap,
  });

  final SpotifyPlaylist playlist;
  final bool isAdded;
  final VoidCallback onAdd;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cover = ClipRRect(
      borderRadius: const BorderRadius.all(Radius.circular(6)),
      child: SizedBox(
        width: 56,
        height: 56,
        child:
            playlist.imageUrl != null
                ? CachedNetworkImage(
                  imageUrl: playlist.imageUrl!,
                  fit: BoxFit.cover,
                  memCacheWidth: 112,
                )
                : const ColoredBox(
                  color: AppColors.surfaceDim,
                  child: Icon(Icons.music_note_rounded),
                ),
      ),
    );

    final trailing =
        isAdded
            ? const Icon(Icons.check_rounded, color: AppColors.success)
            : IconButton(
              onPressed: onAdd,
              icon: const Icon(Icons.add_rounded),
              color: AppColors.primary,
            );

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            cover,
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    playlist.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'Nunito',
                      fontWeight: FontWeight.w600,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${playlist.ownerName} · ${playlist.totalTracks} Titel',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'Nunito',
                      fontSize: 13,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            trailing,
          ],
        ),
      ),
    );
  }
}

// ── Album detail bottom sheet ───────────────────────────────────────────────

class _AlbumDetailSheet extends ConsumerStatefulWidget {
  const _AlbumDetailSheet({
    required this.album,
    required this.isAdded,
    required this.onAdd,
    this.catalogMatch,
  });

  final SpotifyAlbum album;
  final bool isAdded;
  final CatalogMatch? catalogMatch;
  final VoidCallback onAdd;

  @override
  ConsumerState<_AlbumDetailSheet> createState() => _AlbumDetailSheetState();
}

class _AlbumDetailSheetState extends ConsumerState<_AlbumDetailSheet> {
  List<SpotifyTrack>? _tracks;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_loadTracks());
  }

  Future<void> _loadTracks() async {
    try {
      final detail = await ref
          .read(spotifyApiProvider)
          .getAlbum(widget.album.id);
      if (!mounted) return;
      setState(() {
        _tracks = detail?.tracks;
        _loading = false;
      });
    } on Exception catch (e) {
      Log.error(_tag, 'Failed to load album detail', exception: e);
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.3,
      maxChildSize: 0.9,
      expand: false,
      builder: (context, scrollController) {
        return Column(
          children: [
            Container(
              margin: const EdgeInsets.only(top: 8, bottom: 4),
              width: 40,
              height: 4,
              decoration: const BoxDecoration(
                color: AppColors.surfaceDim,
                borderRadius: BorderRadius.all(Radius.circular(2)),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.screenH,
                AppSpacing.sm,
                AppSpacing.screenH,
                AppSpacing.md,
              ),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: const BorderRadius.all(Radius.circular(8)),
                    child: SizedBox(
                      width: 64,
                      height: 64,
                      child:
                          widget.album.imageUrl != null
                              ? CachedNetworkImage(
                                imageUrl: widget.album.imageUrl!,
                                fit: BoxFit.cover,
                              )
                              : const ColoredBox(
                                color: AppColors.surfaceDim,
                                child: Icon(Icons.music_note_rounded),
                              ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.album.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: 'Nunito',
                            fontWeight: FontWeight.w700,
                            fontSize: 16,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          widget.album.artistNames,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: 'Nunito',
                            fontSize: 13,
                            color: AppColors.textSecondary,
                          ),
                        ),
                        if (widget.catalogMatch != null) ...[
                          const SizedBox(height: 4),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.layers_rounded,
                                size: 12,
                                color: AppColors.primary,
                              ),
                              const SizedBox(width: 3),
                              Text(
                                widget.catalogMatch!.series.title,
                                style: const TextStyle(
                                  fontFamily: 'Nunito',
                                  fontSize: 12,
                                  color: AppColors.primary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  if (widget.isAdded)
                    const Icon(Icons.check_rounded, color: AppColors.success)
                  else
                    FilledButton(
                      onPressed: widget.onAdd,
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.md,
                          vertical: AppSpacing.xs,
                        ),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: const Text('Hinzufügen'),
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child:
                  _loading
                      ? const Center(child: CircularProgressIndicator())
                      : _tracks == null || _tracks!.isEmpty
                      ? const Center(
                        child: Text(
                          'Keine Titel verfügbar.',
                          style: TextStyle(
                            fontFamily: 'Nunito',
                            color: AppColors.textSecondary,
                          ),
                        ),
                      )
                      : ListView.builder(
                        controller: scrollController,
                        padding: const EdgeInsets.only(
                          bottom: AppSpacing.xxl,
                          top: AppSpacing.xs,
                        ),
                        itemCount: _tracks!.length,
                        itemBuilder: (context, index) {
                          final track = _tracks![index];
                          return ListTile(
                            dense: true,
                            leading: SizedBox(
                              width: 24,
                              child: Text(
                                '${track.trackNumber}',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontFamily: 'Nunito',
                                  fontSize: 13,
                                  color: AppColors.textSecondary,
                                ),
                              ),
                            ),
                            title: Text(
                              track.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontFamily: 'Nunito',
                                fontSize: 14,
                              ),
                            ),
                            trailing: Text(
                              _formatDuration(track.durationMs),
                              style: const TextStyle(
                                fontFamily: 'Nunito',
                                fontSize: 13,
                                color: AppColors.textSecondary,
                              ),
                            ),
                          );
                        },
                      ),
            ),
          ],
        );
      },
    );
  }
}

// ── Playlist detail bottom sheet ────────────────────────────────────────────

class _PlaylistDetailSheet extends ConsumerStatefulWidget {
  const _PlaylistDetailSheet({
    required this.playlist,
    required this.isAdded,
    required this.onAdd,
  });

  final SpotifyPlaylist playlist;
  final bool isAdded;
  final VoidCallback onAdd;

  @override
  ConsumerState<_PlaylistDetailSheet> createState() =>
      _PlaylistDetailSheetState();
}

class _PlaylistDetailSheetState extends ConsumerState<_PlaylistDetailSheet> {
  List<SpotifyTrack>? _tracks;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_loadTracks());
  }

  Future<void> _loadTracks() async {
    try {
      final detail = await ref
          .read(spotifyApiProvider)
          .getPlaylist(widget.playlist.id);
      if (!mounted) return;
      setState(() {
        _tracks = detail?.tracks;
        _loading = false;
      });
    } on Exception catch (e) {
      Log.error(_tag, 'Failed to load playlist detail', exception: e);
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.3,
      maxChildSize: 0.9,
      expand: false,
      builder: (context, scrollController) {
        return Column(
          children: [
            Container(
              margin: const EdgeInsets.only(top: 8, bottom: 4),
              width: 40,
              height: 4,
              decoration: const BoxDecoration(
                color: AppColors.surfaceDim,
                borderRadius: BorderRadius.all(Radius.circular(2)),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.screenH,
                AppSpacing.sm,
                AppSpacing.screenH,
                AppSpacing.md,
              ),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: const BorderRadius.all(Radius.circular(8)),
                    child: SizedBox(
                      width: 64,
                      height: 64,
                      child:
                          widget.playlist.imageUrl != null
                              ? CachedNetworkImage(
                                imageUrl: widget.playlist.imageUrl!,
                                fit: BoxFit.cover,
                              )
                              : const ColoredBox(
                                color: AppColors.surfaceDim,
                                child: Icon(Icons.music_note_rounded),
                              ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.playlist.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: 'Nunito',
                            fontWeight: FontWeight.w700,
                            fontSize: 16,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${widget.playlist.ownerName} · '
                          '${widget.playlist.totalTracks} Titel',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: 'Nunito',
                            fontSize: 13,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  if (widget.isAdded)
                    const Icon(Icons.check_rounded, color: AppColors.success)
                  else
                    FilledButton(
                      onPressed: widget.onAdd,
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.md,
                          vertical: AppSpacing.xs,
                        ),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: const Text('Hinzufügen'),
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child:
                  _loading
                      ? const Center(child: CircularProgressIndicator())
                      : _tracks == null || _tracks!.isEmpty
                      ? const Center(
                        child: Text(
                          'Keine Titel verfügbar.',
                          style: TextStyle(
                            fontFamily: 'Nunito',
                            color: AppColors.textSecondary,
                          ),
                        ),
                      )
                      : ListView.builder(
                        controller: scrollController,
                        padding: const EdgeInsets.only(
                          bottom: AppSpacing.xxl,
                          top: AppSpacing.xs,
                        ),
                        itemCount: _tracks!.length,
                        itemBuilder: (context, index) {
                          final track = _tracks![index];
                          return ListTile(
                            dense: true,
                            leading: SizedBox(
                              width: 24,
                              child: Text(
                                '${index + 1}',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontFamily: 'Nunito',
                                  fontSize: 13,
                                  color: AppColors.textSecondary,
                                ),
                              ),
                            ),
                            title: Text(
                              track.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontFamily: 'Nunito',
                                fontSize: 14,
                              ),
                            ),
                            subtitle:
                                track.artistNames != null
                                    ? Text(
                                      track.artistNames!,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontFamily: 'Nunito',
                                        fontSize: 12,
                                        color: AppColors.textSecondary,
                                      ),
                                    )
                                    : null,
                            trailing: Text(
                              _formatDuration(track.durationMs),
                              style: const TextStyle(
                                fontFamily: 'Nunito',
                                fontSize: 13,
                                color: AppColors.textSecondary,
                              ),
                            ),
                          );
                        },
                      ),
            ),
          ],
        );
      },
    );
  }
}

// ── Shared ───────────────────────────────────────────────────────────────────

String _formatDuration(int ms) {
  final minutes = ms ~/ 60000;
  final seconds = (ms % 60000) ~/ 1000;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) {
    final hue = (title.hashCode % 360).abs().toDouble();
    return Container(
      width: double.infinity,
      height: double.infinity,
      decoration: BoxDecoration(
        color: HSLColor.fromAHSL(1, hue, 0.3, 0.25).toColor(),
        borderRadius: const BorderRadius.all(AppRadius.card),
      ),
      child: Center(
        child: Icon(
          Icons.headphones_rounded,
          color: HSLColor.fromAHSL(1, hue, 0.4, 0.5).toColor(),
          size: 32,
        ),
      ),
    );
  }
}

/// Fetches album covers for all episodes in a single catalog series.
///
/// Keyed on a comma-joined string of album IDs. Dart lists don't have
/// deep equality, so a list key would restart the fetch on every rebuild.
final _albumCoversProvider = FutureProvider.autoDispose
    .family<Map<String, String>, String>(
      (ref, joinedIds) async {
        final api = ref.watch(spotifyApiProvider);
        if (!api.hasToken || joinedIds.isEmpty) return {};

        final albumIds = joinedIds.split(',');
        final coverMap = <String, String>{};
        for (var i = 0; i < albumIds.length; i += 20) {
          final batch = albumIds.sublist(
            i,
            (i + 20).clamp(0, albumIds.length),
          );
          try {
            final albums = await api.getAlbums(batch);
            for (final album in albums) {
              if (album.imageUrl != null) {
                coverMap[album.id] = album.imageUrl!;
              }
            }
          } on Exception {
            // Skip failed batch, show placeholders.
          }
        }
        return coverMap;
      },
    );

/// Batch-fetches cover images for all curated series.
final _seriesCoverMapProvider = FutureProvider.autoDispose<Map<String, String>>(
  (ref) async {
    final api = ref.watch(spotifyApiProvider);
    if (!api.hasToken) return {};

    final catalogAsync = ref.watch(catalogServiceProvider);
    final catalog = catalogAsync.value;
    if (catalog == null) return {};

    final albumIds = <String>[];
    for (final series in catalog.all) {
      if (series.hasCuratedAlbums) {
        albumIds.add(series.albums.first.spotifyId);
      }
    }

    if (albumIds.isEmpty) return {};

    final coverMap = <String, String>{};
    for (var i = 0; i < albumIds.length; i += 20) {
      final batch = albumIds.sublist(
        i,
        i + 20 > albumIds.length ? albumIds.length : i + 20,
      );
      try {
        final albums = await api.getAlbums(batch);
        for (final album in albums) {
          final url = album.imageUrl;
          if (url != null) {
            coverMap[album.id] = url;
          }
        }
      } on Exception {
        // Skip failed batch, show placeholders
      }
    }

    return coverMap;
  },
);

/// Modal dialog showing batch-add progress.
class _AddProgressDialog extends StatelessWidget {
  const _AddProgressDialog({required this.progress, required this.status});

  /// (loaded, total) pair.
  final ValueNotifier<(int, int)> progress;
  final ValueNotifier<String> status;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ValueListenableBuilder<String>(
              valueListenable: status,
              builder:
                  (_, text, _) => Text(
                    text,
                    style: const TextStyle(
                      fontFamily: 'Nunito',
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                    ),
                  ),
            ),
            const SizedBox(height: AppSpacing.md),
            ValueListenableBuilder<(int, int)>(
              valueListenable: progress,
              builder: (_, pair, _) {
                final (loaded, total) = pair;
                final fraction = total > 0 ? loaded / total : 0.0;
                return Column(
                  children: [
                    ClipRRect(
                      borderRadius: const BorderRadius.all(AppRadius.pill),
                      child: LinearProgressIndicator(
                        value: fraction,
                        minHeight: 6,
                        backgroundColor: AppColors.surfaceDim,
                        valueColor: const AlwaysStoppedAnimation<Color>(
                          AppColors.primary,
                        ),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    Text(
                      '$loaded von $total',
                      style: const TextStyle(
                        fontFamily: 'Nunito',
                        fontSize: 13,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
