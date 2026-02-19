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
/// Debounced search, results list, tap + to add.
/// Stays on screen after adding (add more workflow).
///
/// When [autoAssignGroupId] is set, every added card is immediately
/// assigned to that group — used when navigating from GroupEditScreen.
class AddCardScreen extends ConsumerStatefulWidget {
  const AddCardScreen({super.key, this.autoAssignGroupId});

  /// If set, new cards are assigned to this group automatically.
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

  /// Pre-populate _addedUris from the database so existing cards show ✓.
  Future<void> _loadExistingUris() async {
    final cards = ref.read(cardRepositoryProvider);
    final all = await cards.getAll();
    if (mounted) {
      setState(() {
        _addedUris.addAll(all.map((c) => c.providerUri));
      });
    }
  }

  Future<void> _loadAutoGroup() async {
    final group = await ref
        .read(groupRepositoryProvider)
        .getById(widget.autoAssignGroupId!);
    if (mounted) setState(() => _autoGroup = group);
  }

  @override
  void dispose() {
    _searchController.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _onSearchChanged(String query) {
    _debounce?.cancel();
    if (query.trim().isEmpty) {
      setState(() {
        _results = [];
        _isSearching = false;
      });
      return;
    }
    setState(() => _catalogMatches = []);
    _debounce = Timer(const Duration(milliseconds: 400), () async {
      await _search(query.trim());
    });
  }

  Future<void> _search(String query) async {
    setState(() => _isSearching = true);

    try {
      final api = ref.read(spotifyApiProvider);
      final result = await api.searchAlbums(query);
      if (!mounted) return;
      // Compute catalog matches for each result (synchronous, cheap)
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
      if (mounted) {
        setState(() => _isSearching = false);
      }
    }
  }

  Future<void> _addCard(SpotifyAlbum album, CatalogMatch? match) async {
    final cards = ref.read(cardRepositoryProvider);
    final cardId = await cards.insertIfAbsent(
      title: album.name,
      providerUri: album.uri,
      cardType: 'album',
      coverUrl: album.imageUrl,
    );

    setState(() => _addedUris.add(album.uri));

    if (!mounted) return;

    // Auto-assign mode: directly assign to the group, no snackbar prompt.
    if (widget.autoAssignGroupId != null) {
      final episodeNumber = match?.episodeNumber;
      await ref.read(cardRepositoryProvider).assignToGroup(
        cardId: cardId,
        groupId: widget.autoAssignGroupId!,
        episodeNumber: episodeNumber,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${album.name} zur Serie hinzugefügt'),
            duration: const Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    if (match != null) {
      // Show series-assignment snackbar with action
      final seriesTitle = match.series.title;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${album.name} hinzugefügt'),
          duration: const Duration(seconds: 5),
          behavior: SnackBarBehavior.floating,
          action: SnackBarAction(
            label: 'Zu »$seriesTitle«',
            onPressed: () => unawaited(
              _assignToSeries(cardId, match),
            ),
          ),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${album.name} hinzugefügt'),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  /// Find or create the series group and assign the card to it.
  Future<void> _assignToSeries(String? cardId, CatalogMatch match) async {
    if (cardId == null) return;
    final groupRepo = ref.read(groupRepositoryProvider);

    // Find existing group by series title, or create one
    var group = await groupRepo.findByTitle(match.series.title);
    group ??= await groupRepo
        .insert(title: match.series.title)
        .then(groupRepo.getById);

    if (group == null) return;
    await ref.read(cardRepositoryProvider).assignToGroup(
      cardId: cardId,
      groupId: group.id,
      episodeNumber: match.episodeNumber,
    );

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Zur Serie »${match.series.title}« hinzugefügt'),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
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
          // Series context banner
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
                        final isAdded = _addedUris.contains(album.uri);
                        final match = index < _catalogMatches.length
                            ? _catalogMatches[index]
                            : null;

                        return _SearchResultTile(
                          album: album,
                          isAdded: isAdded,
                          catalogMatch: match,
                          onAdd: () => unawaited(_addCard(album, match)),
                        );
                      },
                    ),
          ),
        ],
      ),
    );
  }
}

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
                      ? '${catalogMatch!.series.title} · '
                          'Folge ${catalogMatch!.episodeNumber}'
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
