import 'dart:async' show Timer, unawaited;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lauschi/core/catalog/catalog_service.dart';
import 'package:lauschi/core/database/app_database.dart' as db;
import 'package:lauschi/core/database/card_repository.dart';
import 'package:lauschi/core/database/group_repository.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/spotify/spotify_api.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/player/player_provider.dart';

const _tag = 'AddCard';

/// Search Spotify and add albums as cards to the collection.
///
/// When a catalog series is detected, tapping + opens [_SeriesAssignSheet]
/// so the parent can decide whether to add the episode to that series or not.
/// When [autoAssignGroupId] is set (via GroupEditScreen FAB), every added
/// card is silently assigned to that group — no sheet needed.
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
      final matches = catalog != null
          ? result.albums.map((a) => catalog.match(a.name)).toList()
          : List<CatalogMatch?>.filled(result.albums.length, null);
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

  /// Entry point when the user taps +.
  ///
  /// - Auto-assign mode (from GroupEditScreen): add + assign silently.
  /// - Series detected: show [_SeriesAssignSheet] for an explicit decision.
  /// - No match: add directly.
  Future<void> _handleAddTap(SpotifyAlbum album, CatalogMatch? match) async {
    if (widget.autoAssignGroupId != null) {
      await _addAndAssignToGroup(album, widget.autoAssignGroupId!, match);
      return;
    }

    if (match != null) {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (_) => _SeriesAssignSheet(
          album: album,
          match: match,
          onComplete: (uri) => setState(() => _addedUris.add(uri)),
        ),
      );
      return;
    }

    await _addOnly(album);
  }

  /// Add the card and assign it to [groupId] silently (auto-assign mode).
  Future<void> _addAndAssignToGroup(
    SpotifyAlbum album,
    String groupId,
    CatalogMatch? match,
  ) async {
    final cardId = await ref.read(cardRepositoryProvider).insertIfAbsent(
          title: album.name,
          providerUri: album.uri,
          cardType: 'album',
          coverUrl: album.imageUrl,
        );
    await ref.read(cardRepositoryProvider).assignToGroup(
          cardId: cardId,
          groupId: groupId,
          episodeNumber: match?.episodeNumber,
        );
    if (mounted) {
      setState(() => _addedUris.add(album.uri));
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('${album.name} zur Serie hinzugefügt'),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  /// Add the card without any series assignment.
  Future<void> _addOnly(SpotifyAlbum album) async {
    await ref.read(cardRepositoryProvider).insertIfAbsent(
          title: album.name,
          providerUri: album.uri,
          cardType: 'album',
          coverUrl: album.imageUrl,
        );
    if (mounted) {
      setState(() => _addedUris.add(album.uri));
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('${album.name} hinzugefügt'),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
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
                  const Icon(Icons.layers_rounded,
                      size: 16, color: AppColors.primary),
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

          // Results
          Expanded(
            child: _isSearching
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
                        padding:
                            const EdgeInsets.only(bottom: AppSpacing.xxl),
                        cacheExtent: 500,
                        itemBuilder: (context, index) {
                          final album = _results[index];
                          final match = index < _catalogMatches.length
                              ? _catalogMatches[index]
                              : null;
                          return _SearchResultTile(
                            album: album,
                            isAdded: _addedUris.contains(album.uri),
                            catalogMatch: match,
                            onAdd: () =>
                                unawaited(_handleAddTap(album, match)),
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
// Search result tile
// ---------------------------------------------------------------------------

class _SearchResultTile extends StatelessWidget {
  const _SearchResultTile({
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
  Widget build(BuildContext context) {
    return ListTile(
      leading: ClipRRect(
        borderRadius: const BorderRadius.all(Radius.circular(6)),
        child: SizedBox(
          width: 48,
          height: 48,
          child: album.imageUrl != null
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
                const Icon(Icons.layers_rounded,
                    size: 11, color: AppColors.primary),
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
      trailing: isAdded
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
// Series assignment sheet
// ---------------------------------------------------------------------------

/// Bottom sheet shown when a catalog series is detected.
///
/// The parent decides whether to add the episode to the series or not.
/// The card is only written to the database after the user makes a choice.
class _SeriesAssignSheet extends ConsumerStatefulWidget {
  const _SeriesAssignSheet({
    required this.album,
    required this.match,
    required this.onComplete,
  });

  final SpotifyAlbum album;
  final CatalogMatch match;

  /// Called with the album URI once the card has been added (either path).
  final void Function(String uri) onComplete;

  @override
  ConsumerState<_SeriesAssignSheet> createState() =>
      _SeriesAssignSheetState();
}

class _SeriesAssignSheetState extends ConsumerState<_SeriesAssignSheet> {
  bool _loading = false;

  Future<void> _addToSeries() async {
    setState(() => _loading = true);
    try {
      final cardId =
          await ref.read(cardRepositoryProvider).insertIfAbsent(
                title: widget.album.name,
                providerUri: widget.album.uri,
                cardType: 'album',
                coverUrl: widget.album.imageUrl,
              );

      final groupRepo = ref.read(groupRepositoryProvider);
      var group = await groupRepo.findByTitle(widget.match.series.title);
      group ??= await groupRepo
          .insert(title: widget.match.series.title)
          .then(groupRepo.getById);

      if (group != null) {
        await ref.read(cardRepositoryProvider).assignToGroup(
              cardId: cardId,
              groupId: group.id,
              episodeNumber: widget.match.episodeNumber,
            );
      }

      widget.onComplete(widget.album.uri);
      if (mounted) Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _addWithout() async {
    setState(() => _loading = true);
    try {
      await ref.read(cardRepositoryProvider).insertIfAbsent(
            title: widget.album.name,
            providerUri: widget.album.uri,
            cardType: 'album',
            coverUrl: widget.album.imageUrl,
          );
      widget.onComplete(widget.album.uri);
      if (mounted) Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final album = widget.album;
    final match = widget.match;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.screenH,
          AppSpacing.lg,
          AppSpacing.screenH,
          AppSpacing.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Drag handle
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: const BoxDecoration(
                  color: AppColors.surfaceDim,
                  borderRadius: BorderRadius.all(Radius.circular(2)),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.lg),

            // Album row
            Row(
              children: [
                ClipRRect(
                  borderRadius: const BorderRadius.all(AppRadius.card),
                  child: SizedBox(
                    width: 64,
                    height: 64,
                    child: album.imageUrl != null
                        ? CachedNetworkImage(
                            imageUrl: album.imageUrl!,
                            fit: BoxFit.cover,
                          )
                        : const ColoredBox(
                            color: AppColors.surfaceDim,
                            child: Icon(Icons.music_note_rounded, size: 28),
                          ),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        album.name,
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
                        '${album.artistNames} · ${album.totalTracks} Titel',
                        style: const TextStyle(
                          fontFamily: 'Nunito',
                          fontSize: 13,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),

            const SizedBox(height: AppSpacing.lg),

            // Detected series card
            Container(
              padding: const EdgeInsets.all(AppSpacing.md),
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.08),
                borderRadius: const BorderRadius.all(AppRadius.card),
              ),
              child: Row(
                children: [
                  const Icon(Icons.layers_rounded,
                      color: AppColors.primary, size: 22),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          match.series.title,
                          style: const TextStyle(
                            fontFamily: 'Nunito',
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
                            color: AppColors.primary,
                          ),
                        ),
                        if (match.episodeNumber != null)
                          Text(
                            'Folge ${match.episodeNumber} erkannt',
                            style: const TextStyle(
                              fontFamily: 'Nunito',
                              fontSize: 13,
                              color: AppColors.primary,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: AppSpacing.xl),

            // Primary action
            FilledButton(
              onPressed: _loading ? null : _addToSeries,
              child: _loading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: AppColors.textOnPrimary,
                      ),
                    )
                  : Text('Zur Serie »${match.series.title}« hinzufügen'),
            ),

            const SizedBox(height: AppSpacing.sm),

            // Secondary action
            OutlinedButton(
              onPressed: _loading ? null : _addWithout,
              child: const Text('Ohne Serie hinzufügen'),
            ),
          ],
        ),
      ),
    );
  }
}
