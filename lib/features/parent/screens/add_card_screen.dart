import 'dart:async' show Timer, unawaited;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lauschi/core/catalog/catalog_service.dart';
import 'package:lauschi/core/database/app_database.dart' as db;
import 'package:lauschi/core/database/card_repository.dart';
import 'package:lauschi/core/database/group_repository.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/router/app_router.dart';
import 'package:lauschi/core/spotify/spotify_api.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/player/player_provider.dart';

const _tag = 'AddCard';

/// Search Spotify and add albums as cards to the collection.
///
/// When a catalog series is detected, the card is auto-assigned to that
/// series group with no confirmation needed. An undo snackbar is shown.
///
/// When [autoAssignGroupId] is set (via GroupEditScreen FAB), every added
/// card is silently assigned to that group — no snackbar, no undo.
class AddCardScreen extends ConsumerStatefulWidget {
  const AddCardScreen({super.key, this.autoAssignGroupId});

  final String? autoAssignGroupId;

  @override
  ConsumerState<AddCardScreen> createState() => _AddCardScreenState();
}

class _AddCardScreenState extends ConsumerState<AddCardScreen> {
  final _searchController = TextEditingController();
  Timer? _debounce;
  List<SpotifyAlbum> _results = [];
  List<CatalogMatch?> _catalogMatches = [];
  bool _isSearching = false;
  final _addedUris = <String>{};
  db.CardGroup? _autoGroup;

  // Snackbar debounce — batches rapid additions into a single notification.
  Timer? _snackTimer;
  int _pendingAdded = 0;
  int _pendingAssigned = 0;
  String _lastSeriesTitle = '';

  @override
  void initState() {
    super.initState();
    unawaited(_loadExistingUris());
    if (widget.autoAssignGroupId != null) {
      unawaited(_loadAutoGroup());
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _debounce?.cancel();
    _snackTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadExistingUris() async {
    final all = await ref.read(cardRepositoryProvider).getAll();
    if (mounted) {
      setState(() => _addedUris.addAll(all.map((c) => c.providerUri)));
    }
  }

  Future<void> _loadAutoGroup() async {
    final group = await ref
        .read(groupRepositoryProvider)
        .getById(widget.autoAssignGroupId!);
    if (mounted) setState(() => _autoGroup = group);
  }

  void _onSearchChanged(String query) {
    _debounce?.cancel();
    if (query.trim().isEmpty) {
      setState(() {
        _results = [];
        _catalogMatches = [];
        _isSearching = false;
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
      final result = await ref.read(spotifyApiProvider).searchAlbums(query);
      if (!mounted) return;
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
          'results': result.albums.length,
          'catalogHits': catalogHits,
        },
      );
      setState(() {
        _results = result.albums;
        _catalogMatches = matches;
        _isSearching = false;
      });
    } on Exception catch (e) {
      Log.error(_tag, 'Search failed', exception: e);
      if (mounted) setState(() => _isSearching = false);
    }
  }

  // -------------------------------------------------------------------------
  // Add logic
  // -------------------------------------------------------------------------

  Future<void> _handleAddTap(SpotifyAlbum album, CatalogMatch? match) async {
    if (widget.autoAssignGroupId != null) {
      await _addAndAssign(album, widget.autoAssignGroupId!, match);
      return;
    }

    if (match != null) {
      // Auto-assign to series — find or create the group silently.
      final groupId = await _findOrCreateGroup(match.series.title);
      await _addAndAssign(album, groupId, match, showUndo: true);
      return;
    }

    await _addOnly(album);
  }

  /// Add all visible search results that match [seriesTitle] to that series.
  Future<void> _handleAddAll(String seriesTitle) async {
    final groupId = await _findOrCreateGroup(seriesTitle);
    var count = 0;
    for (var i = 0; i < _results.length; i++) {
      final album = _results[i];
      if (_addedUris.contains(album.uri)) continue;
      final match = i < _catalogMatches.length ? _catalogMatches[i] : null;
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
    final groupRepo = ref.read(groupRepositoryProvider);
    final existing = await groupRepo.findByTitle(seriesTitle);
    if (existing != null) return existing.id;
    return groupRepo.insert(title: seriesTitle);
  }

  /// Insert card + assign to group. Optionally shows a snackbar with undo.
  Future<void> _addAndAssign(
    SpotifyAlbum album,
    String groupId,
    CatalogMatch? match, {
    bool showUndo = false,
    bool silent = false,
  }) async {
    final cardId = await ref
        .read(cardRepositoryProvider)
        .insertIfAbsent(
          title: album.name,
          providerUri: album.uri,
          cardType: 'album',
          coverUrl: album.imageUrl,
          spotifyArtistIds: album.artistIds,
        );
    await ref
        .read(cardRepositoryProvider)
        .assignToGroup(
          cardId: cardId,
          groupId: groupId,
          episodeNumber: match?.episodeNumber,
        );
    if (!mounted) return;
    setState(() => _addedUris.add(album.uri));

    if (silent) return;

    if (showUndo) {
      // Batched undo snackbar — shows after 500 ms to coalesce rapid adds.
      _pendingAssigned++;
      _lastSeriesTitle = match?.series.title ?? '';
      _snackTimer?.cancel();
      _snackTimer = Timer(const Duration(milliseconds: 500), () {
        if (!mounted) return;
        final n = _pendingAssigned;
        _pendingAssigned = 0;
        final label =
            n == 1
                ? 'Zu »$_lastSeriesTitle« hinzugefügt'
                : '$n Folgen zu »$_lastSeriesTitle« hinzugefügt';

        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(
            SnackBar(
              content: Text(label),
              behavior: SnackBarBehavior.floating,
              action: SnackBarAction(
                label: 'Rückgängig',
                onPressed:
                    () => unawaited(
                      ref.read(cardRepositoryProvider).removeFromGroup(cardId),
                    ),
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
        .read(cardRepositoryProvider)
        .insertIfAbsent(
          title: album.name,
          providerUri: album.uri,
          cardType: 'album',
          coverUrl: album.imageUrl,
          spotifyArtistIds: album.artistIds,
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

  // -------------------------------------------------------------------------
  // Album detail
  // -------------------------------------------------------------------------

  Future<void> _showAlbumDetail(SpotifyAlbum album, CatalogMatch? match) async {
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

  // -------------------------------------------------------------------------
  // Series detection
  // -------------------------------------------------------------------------

  /// Distinct series detected in current search results, ordered by number
  /// of matching albums (most matches first). Skips series that already
  /// exist as groups (user already added them).
  List<CatalogSeries> _detectedSeries() {
    final counts = <String, int>{}; // series.id → count
    final seriesMap = <String, CatalogSeries>{};
    for (var i = 0; i < _results.length; i++) {
      final match = i < _catalogMatches.length ? _catalogMatches[i] : null;
      if (match == null) continue;
      final sid = match.series.id;
      counts[sid] = (counts[sid] ?? 0) + 1;
      seriesMap[sid] = match.series;
    }
    if (counts.isEmpty) return [];

    // Sort by match count descending
    final sorted =
        counts.keys.toList()..sort((a, b) => counts[b]!.compareTo(counts[a]!));
    return sorted.map((id) => seriesMap[id]!).toList();
  }

  // -------------------------------------------------------------------------
  // Bulk series add
  // -------------------------------------------------------------------------

  Future<void> _addSeriesFromCatalog(CatalogSeries series) async {
    final groupId = await _findOrCreateGroup(series.title);
    if (!mounted) return;

    final sw = Stopwatch()..start();
    var added = 0;
    var failed = 0;
    final albumIds = series.albums.map((a) => a.spotifyId).toList();

    // Show progress dialog
    final totalCount = albumIds.length;
    var progressCount = 0;
    final progressNotifier = ValueNotifier<double>(0);

    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder:
            (_) => ValueListenableBuilder<double>(
              valueListenable: progressNotifier,
              builder:
                  (_, progress, _) => AlertDialog(
                    content: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        LinearProgressIndicator(value: progress),
                        const SizedBox(height: AppSpacing.md),
                        Text(
                          '${(progress * 100).round()}% — $progressCount von $totalCount Folgen',
                          style: const TextStyle(
                            fontFamily: 'Nunito',
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  ),
            ),
      ),
    );

    try {
      // Fetch in batches of 20 (Spotify API limit)
      for (var i = 0; i < albumIds.length; i += 20) {
        final batch = albumIds.sublist(
          i,
          (i + 20).clamp(0, albumIds.length),
        );
        List<SpotifyAlbum> albums;
        try {
          albums = await ref.read(spotifyApiProvider).getAlbums(batch);
        } on Exception catch (e) {
          Log.error(
            _tag,
            'Batch fetch failed',
            exception: e,
            data: {
              'batch': '${i ~/ 20 + 1}',
              'ids': batch.length,
            },
          );
          failed += batch.length;
          progressCount += batch.length;
          if (mounted) {
            progressNotifier.value = progressCount / totalCount;
          }
          continue;
        }

        for (final album in albums) {
          // Look up episode number from catalog
          final catalogAlbum =
              series.albums.where((a) => a.spotifyId == album.id).firstOrNull;
          final cardId = await ref
              .read(cardRepositoryProvider)
              .insertIfAbsent(
                title: album.name,
                providerUri: album.uri,
                cardType: 'album',
                coverUrl: album.imageUrl,
                spotifyArtistIds: album.artistIds,
              );
          await ref
              .read(cardRepositoryProvider)
              .assignToGroup(
                cardId: cardId,
                groupId: groupId,
                episodeNumber: catalogAlbum?.episode,
              );
          added++;
          if (mounted) setState(() => _addedUris.add(album.uri));
        }

        // Track albums that were in the batch request but not returned
        failed += batch.length - albums.length;

        progressCount += batch.length;
        if (mounted) {
          progressNotifier.value = progressCount / totalCount;
        }
      }
    } on Exception catch (e) {
      Log.error(_tag, 'Series bulk add failed', exception: e);
    }

    sw.stop();
    Log.info(
      _tag,
      'Series bulk add complete',
      data: {
        'series': series.id,
        'catalogAlbums': totalCount,
        'added': added,
        'failed': failed,
        'durationMs': sw.elapsedMilliseconds,
        'batches': (totalCount / 20).ceil(),
      },
    );

    progressNotifier.dispose();
    if (mounted) Navigator.of(context).pop(); // close progress dialog

    if (mounted) {
      unawaited(context.push(AppRoutes.parentGroupEdit(groupId)));
    }
  }

  /// Add a detected series using just the visible search results (no catalog
  /// album data). Creates the group and adds matching albums.
  Future<void> _addSeriesFromSearch(CatalogSeries series) async {
    final groupId = await _findOrCreateGroup(series.title);

    var count = 0;
    for (var i = 0; i < _results.length; i++) {
      final album = _results[i];
      if (_addedUris.contains(album.uri)) continue;
      final match = i < _catalogMatches.length ? _catalogMatches[i] : null;
      if (match?.series.id != series.id) continue;

      final cardId = await ref
          .read(cardRepositoryProvider)
          .insertIfAbsent(
            title: album.name,
            providerUri: album.uri,
            cardType: 'album',
            coverUrl: album.imageUrl,
            spotifyArtistIds: album.artistIds,
          );
      await ref
          .read(cardRepositoryProvider)
          .assignToGroup(
            cardId: cardId,
            groupId: groupId,
            episodeNumber: match?.episodeNumber,
          );
      if (mounted) setState(() => _addedUris.add(album.uri));
      count++;
    }

    Log.info(
      _tag,
      'Series search add',
      data: {
        'series': series.id,
        'added': count,
      },
    );

    if (mounted) {
      unawaited(context.push(AppRoutes.parentGroupEdit(groupId)));
    }
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    // Detect series in results (only in general add mode)
    final detectedSeries =
        widget.autoAssignGroupId == null && _results.isNotEmpty
            ? _detectedSeries()
            : <CatalogSeries>[];

    // In autoAssign mode, offer batch add when all results match one series
    String? batchSeries;
    if (widget.autoAssignGroupId != null && _results.isNotEmpty) {
      String? title;
      var allMatch = true;
      for (var i = 0; i < _results.length; i++) {
        if (_addedUris.contains(_results[i].uri)) continue;
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
        title: const Text('Hörspiel hinzufügen'),
      ),
      body: Column(
        children: [
          // Auto-assign mode banner
          if (widget.autoAssignGroupId != null)
            Container(
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
                      _autoGroup != null
                          ? 'Folgen werden direkt zu »${_autoGroup!.title}« hinzugefügt'
                          : 'Folgen werden direkt zur Serie hinzugefügt',
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
            ),

          // Search field
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.screenH,
              vertical: AppSpacing.sm,
            ),
            child: TextField(
              controller: _searchController,
              onChanged: _onSearchChanged,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'Suche auf Spotify...',
                prefixIcon: Icon(Icons.search_rounded),
              ),
            ),
          ),

          // Batch-add banner — autoAssign mode only
          if (batchSeries case final seriesTitle?)
            _BatchAddBanner(
              seriesTitle: seriesTitle,
              count: _results.where((a) => !_addedUris.contains(a.uri)).length,
              onAddAll: () => unawaited(_handleAddAll(seriesTitle)),
            ),

          // Series cards — general add mode
          if (detectedSeries.isNotEmpty)
            ...detectedSeries.map(
              (series) => _SeriesCard(
                series: series,
                matchCount:
                    _catalogMatches
                        .whereType<CatalogMatch>()
                        .where((m) => m.series.id == series.id)
                        .length,
                onAdd:
                    () =>
                        series.hasCuratedAlbums
                            ? unawaited(_addSeriesFromCatalog(series))
                            : unawaited(_addSeriesFromSearch(series)),
              ),
            ),

          // Results
          Expanded(
            child:
                _isSearching
                    ? const Center(child: CircularProgressIndicator())
                    : _results.isEmpty
                    ? Center(
                      child: Text(
                        _searchController.text.isEmpty
                            ? 'Suche nach Hörspielen, Hörbüchern oder Alben.'
                            : 'Keine Ergebnisse.',
                        style: const TextStyle(
                          fontFamily: 'Nunito',
                          fontSize: 15,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    )
                    : ListView.builder(
                      itemCount: _results.length,
                      padding: const EdgeInsets.only(bottom: AppSpacing.xxl),
                      cacheExtent: 500,
                      itemBuilder: (context, index) {
                        final album = _results[index];
                        final match =
                            index < _catalogMatches.length
                                ? _catalogMatches[index]
                                : null;
                        return _SearchResultTile(
                          album: album,
                          isAdded: _addedUris.contains(album.uri),
                          catalogMatch: match,
                          onAdd: () => unawaited(_handleAddTap(album, match)),
                          onTap:
                              () => unawaited(_showAlbumDetail(album, match)),
                        );
                      },
                    ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Batch-add banner
// ---------------------------------------------------------------------------

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
              ? 'Zur Serie »$seriesTitle« hinzufügen'
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

// ---------------------------------------------------------------------------
// Series card — shown when search results match a known catalog series
// ---------------------------------------------------------------------------

class _SeriesCard extends StatelessWidget {
  const _SeriesCard({
    required this.series,
    required this.matchCount,
    required this.onAdd,
  });

  final CatalogSeries series;

  /// How many search results matched this series.
  final int matchCount;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final hasAlbums = series.hasCuratedAlbums;
    final subtitle =
        hasAlbums
            ? '${series.albums.length} Folgen im Katalog'
            : '$matchCount ${matchCount == 1 ? 'Treffer' : 'Treffer'} in Ergebnissen';

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
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.xs,
        ),
        leading: const Icon(
          Icons.library_music_rounded,
          color: AppColors.primary,
          size: 28,
        ),
        title: Text(
          series.title,
          style: const TextStyle(
            fontFamily: 'Nunito',
            fontWeight: FontWeight.w700,
            fontSize: 15,
            color: AppColors.primary,
          ),
        ),
        subtitle: Text(
          subtitle,
          style: const TextStyle(
            fontFamily: 'Nunito',
            fontSize: 12,
            color: AppColors.primary,
          ),
        ),
        trailing: FilledButton(
          onPressed: onAdd,
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.xs,
            ),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: const Text('Serie anlegen'),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Search result tile
// ---------------------------------------------------------------------------

class _SearchResultTile extends StatelessWidget {
  const _SearchResultTile({
    required this.album,
    required this.isAdded,
    required this.onAdd,
    required this.onTap,
    this.catalogMatch,
  });

  final SpotifyAlbum album;
  final bool isAdded;
  final CatalogMatch? catalogMatch;
  final VoidCallback onAdd;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      leading: ClipRRect(
        borderRadius: const BorderRadius.all(Radius.circular(6)),
        child: SizedBox(
          width: 48,
          height: 48,
          child:
              album.imageUrl != null
                  ? CachedNetworkImage(
                    imageUrl: album.imageUrl!,
                    fit: BoxFit.cover,
                    memCacheWidth: 96,
                  )
                  : const ColoredBox(
                    color: AppColors.surfaceDim,
                    child: Icon(Icons.music_note_rounded),
                  ),
        ),
      ),
      title: Text(
        album.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          fontFamily: 'Nunito',
          fontWeight: FontWeight.w600,
          fontSize: 15,
        ),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
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
          if (catalogMatch != null) ...[
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
                Text(
                  catalogMatch!.episodeNumber != null
                      ? '${catalogMatch!.series.title} · Folge ${catalogMatch!.episodeNumber}'
                      : catalogMatch!.series.title,
                  style: const TextStyle(
                    fontFamily: 'Nunito',
                    fontSize: 11,
                    color: AppColors.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
      isThreeLine: catalogMatch != null,
      trailing:
          isAdded
              ? const Icon(Icons.check_rounded, color: AppColors.success)
              : IconButton(
                onPressed: onAdd,
                icon: const Icon(Icons.add_rounded),
                color: AppColors.primary,
              ),
    );
  }
}

// ---------------------------------------------------------------------------
// Album detail bottom sheet — shows track listing
// ---------------------------------------------------------------------------

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

  String _formatDuration(int ms) {
    final minutes = ms ~/ 60000;
    final seconds = (ms % 60000) ~/ 1000;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
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
            // Handle
            Container(
              margin: const EdgeInsets.only(top: 8, bottom: 4),
              width: 40,
              height: 4,
              decoration: const BoxDecoration(
                color: AppColors.surfaceDim,
                borderRadius: BorderRadius.all(Radius.circular(2)),
              ),
            ),

            // Album header
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

            // Track listing
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
