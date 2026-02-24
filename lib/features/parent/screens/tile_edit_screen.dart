import 'dart:async' show unawaited;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lauschi/core/database/app_database.dart' as db;
import 'package:lauschi/core/database/tile_item_repository.dart';
import 'package:lauschi/core/database/tile_repository.dart';
import 'package:lauschi/core/router/app_router.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/tiles/screens/tile_detail_screen.dart';
import 'package:lauschi/features/player/player_provider.dart';

/// Parent edit screen for a single series group.
///
/// Title / cover are editable; episodes are shown in order and can be
/// reordered or removed. Cards are assigned from the series manager.
class TileEditScreen extends ConsumerStatefulWidget {
  const TileEditScreen({required this.tileId, super.key});

  final String tileId;

  @override
  ConsumerState<TileEditScreen> createState() => _GroupEditScreenState();
}

class _GroupEditScreenState extends ConsumerState<TileEditScreen> {
  late final TextEditingController _titleController;
  late final TextEditingController _coverController;
  bool _dirty = false;
  // Set to true after the first data load. Prevents _onLoaded from
  // overwriting user-edited values with stale stream data after _save()
  // resets _dirty to false.
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController();
    _coverController = TextEditingController();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _coverController.dispose();
    super.dispose();
  }

  void _onLoaded(db.Tile group) {
    if (_initialized) return; // Controllers already set; don't clobber edits
    _titleController.text = group.title;
    _coverController.text = group.coverUrl ?? '';
    _initialized = true;
  }

  void _confirmDeleteAllCards(BuildContext context) {
    unawaited(
      showDialog<void>(
        context: context,
        builder:
            (ctx) => AlertDialog(
              title: const Text('Alle Folgen löschen?'),
              content: const Text(
                'Alle Einträge in dieser Kachel werden unwiderruflich '
                'entfernt. Die Kachel selbst bleibt bestehen.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Abbrechen'),
                ),
                FilledButton(
                  onPressed: () async {
                    Navigator.of(ctx).pop();
                    final count = await ref
                        .read(tileItemRepositoryProvider)
                        .deleteByTile(widget.tileId);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context)
                        ..clearSnackBars()
                        ..showSnackBar(
                          SnackBar(
                            content: Text(
                              '$count ${count == 1 ? 'Eintrag' : 'Einträge'} '
                              'entfernt',
                            ),
                            behavior: SnackBarBehavior.floating,
                          ),
                        );
                    }
                  },
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.error,
                  ),
                  child: const Text('Alle löschen'),
                ),
              ],
            ),
      ),
    );
  }

  void _confirmDeleteGroup(BuildContext context) {
    unawaited(
      showDialog<void>(
        context: context,
        builder:
            (ctx) => AlertDialog(
              title: const Text('Kachel löschen?'),
              content: const Text(
                'Die Kachel und alle zugehörigen Einträge werden '
                'unwiderruflich entfernt.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Abbrechen'),
                ),
                FilledButton(
                  onPressed: () async {
                    Navigator.of(ctx).pop();
                    await ref
                        .read(tileItemRepositoryProvider)
                        .deleteByTile(widget.tileId);
                    await ref
                        .read(tileRepositoryProvider)
                        .delete(widget.tileId);
                    if (context.mounted) {
                      if (context.canPop()) {
                        context.pop();
                      } else {
                        context.go(AppRoutes.parentManageTiles);
                      }
                    }
                  },
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.error,
                  ),
                  child: const Text('Kachel löschen'),
                ),
              ],
            ),
      ),
    );
  }

  Future<void> _save() async {
    final title = _titleController.text.trim();
    if (title.isEmpty) return;
    await ref
        .read(tileRepositoryProvider)
        .update(
          id: widget.tileId,
          title: title,
          coverUrl:
              _coverController.text.trim().isEmpty
                  ? null
                  : _coverController.text.trim(),
          clearCoverUrl: _coverController.text.trim().isEmpty,
        );
    if (mounted) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          const SnackBar(
            content: Text('Kachel gespeichert'),
            duration: Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
      setState(() => _dirty = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final groupAsync = ref.watch(tileByIdProvider(widget.tileId));
    final episodesAsync = ref.watch(tileItemsProvider(widget.tileId));

    return groupAsync.when(
      data: (group) {
        if (group == null) {
          return Scaffold(
            appBar: AppBar(title: const Text('Kachel')),
            body: const Center(child: Text('Kachel nicht gefunden')),
          );
        }
        _onLoaded(group);
        return _buildScaffold(context, group, episodesAsync);
      },
      loading:
          () => Scaffold(
            appBar: AppBar(title: const Text('Kachel')),
            body: const Center(child: CircularProgressIndicator()),
          ),
      error:
          (_, _) => Scaffold(
            appBar: AppBar(title: const Text('Kachel')),
            body: const Center(child: Text('Fehler beim Laden')),
          ),
    );
  }

  Widget _buildScaffold(
    BuildContext context,
    db.Tile group,
    AsyncValue<List<db.TileItem>> episodesAsync,
  ) {
    final episodes = episodesAsync.value ?? <db.TileItem>[];
    final episodeCovers =
        episodes.map((e) => e.coverUrl).whereType<String>().toSet().toList();

    // Collect unique artist IDs from group's cards for artist image covers.
    final artistIds =
        episodes
            .map((e) => e.spotifyArtistIds)
            .whereType<String>()
            .expand((ids) => ids.split(','))
            .map((id) => id.trim())
            .where((id) => id.isNotEmpty)
            .toSet()
            .toList();

    return Scaffold(
      backgroundColor: AppColors.parentBackground,
      appBar: AppBar(
        backgroundColor: AppColors.parentBackground,
        title: const Text('Kachel bearbeiten'),
        actions: [
          if (_dirty)
            TextButton(
              onPressed: _save,
              child: const Text('Speichern'),
            ),
          PopupMenuButton<String>(
            onSelected: (action) {
              switch (action) {
                case 'delete_cards':
                  _confirmDeleteAllCards(context);
                case 'delete_group':
                  _confirmDeleteGroup(context);
              }
            },
            itemBuilder:
                (_) => [
                  const PopupMenuItem(
                    value: 'delete_cards',
                    child: Text('Alle Folgen löschen'),
                  ),
                  const PopupMenuItem(
                    value: 'delete_group',
                    child: Text('Kachel löschen'),
                  ),
                ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed:
            () => unawaited(
              context.push(AppRoutes.parentAddCardToTile(widget.tileId)),
            ),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Folge hinzufügen'),
      ),
      body: Column(
        children: [
          // Meta fields
          Container(
            color: AppColors.parentSurface,
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.screenH,
              AppSpacing.md,
              AppSpacing.screenH,
              AppSpacing.lg,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: _titleController,
                  decoration: const InputDecoration(
                    labelText: 'Name der Kachel',
                  ),
                  onChanged: (_) => setState(() => _dirty = true),
                  textCapitalization: TextCapitalization.sentences,
                ),
                const SizedBox(height: AppSpacing.md),
                _CoverPicker(
                  controller: _coverController,
                  episodeCovers: episodeCovers,
                  artistIds: artistIds,
                  onChanged: () => setState(() => _dirty = true),
                  onAutoSave: _save,
                ),
              ],
            ),
          ),

          // Episodes header
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.screenH,
              AppSpacing.md,
              AppSpacing.screenH,
              AppSpacing.xs,
            ),
            child: Row(
              children: [
                Text(
                  'FOLGEN'.toUpperCase(),
                  style: const TextStyle(
                    fontFamily: 'Nunito',
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                    color: AppColors.textSecondary,
                  ),
                ),
                const Spacer(),
                Text(
                  episodes.isEmpty ? '' : '${episodes.length}',
                  style: const TextStyle(
                    fontFamily: 'Nunito',
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),

          // Episode list
          Expanded(
            child: episodesAsync.when(
              data:
                  (eps) =>
                      eps.isEmpty
                          ? const _EmptyEpisodesHint()
                          : _EpisodeReorderList(
                            tileId: widget.tileId,
                            episodes: eps,
                          ),
              loading: () => const Center(child: CircularProgressIndicator()),
              error:
                  (_, _) => const Center(
                    child: Text('Fehler beim Laden der Folgen.'),
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Cover picker: shows current cover, episode cover chips, and a URL fallback.
// ---------------------------------------------------------------------------

class _CoverPicker extends ConsumerStatefulWidget {
  const _CoverPicker({
    required this.controller,
    required this.episodeCovers,
    required this.onChanged,
    this.artistIds = const [],
    this.onAutoSave,
  });

  final TextEditingController controller;

  /// Distinct cover URLs already present in the group's episodes.
  final List<String> episodeCovers;

  /// Spotify artist IDs to fetch artist images from.
  final List<String> artistIds;

  /// Called when any cover value changes (marks the form dirty).
  final VoidCallback onChanged;

  /// Called immediately when an episode thumbnail is tapped — auto-saves
  /// without requiring the user to tap a separate "Speichern" button.
  final Future<void> Function()? onAutoSave;

  @override
  ConsumerState<_CoverPicker> createState() => _CoverPickerState();
}

class _CoverPickerState extends ConsumerState<_CoverPicker> {
  String get _currentUrl => widget.controller.text.trim();
  final _artistImages = <String>[];
  bool _artistImagesFetched = false;

  @override
  void initState() {
    super.initState();
    unawaited(_fetchArtistImages());
  }

  @override
  void didUpdateWidget(_CoverPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.artistIds != widget.artistIds) {
      _artistImagesFetched = false;
      _artistImages.clear();
      unawaited(_fetchArtistImages());
    }
  }

  Future<void> _fetchArtistImages() async {
    if (widget.artistIds.isEmpty || _artistImagesFetched) return;
    _artistImagesFetched = true;

    final api = ref.read(spotifyApiProvider);

    for (final id in widget.artistIds) {
      try {
        final url = await api.getArtistImage(id);
        if (url != null && mounted) {
          setState(() => _artistImages.add(url));
        }
      } on Exception {
        // Artist image fetch is best-effort.
      }
    }
  }

  void _pickCover(String url) {
    widget.controller.text = url;
    widget.onChanged();
    if (widget.onAutoSave != null) unawaited(widget.onAutoSave!());
  }

  void _clearCover() {
    widget.controller.clear();
    widget.onChanged();
    if (widget.onAutoSave != null) unawaited(widget.onAutoSave!());
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            // Cover preview
            ClipRRect(
              borderRadius: const BorderRadius.all(AppRadius.card),
              child: SizedBox(
                width: 72,
                height: 72,
                child:
                    _currentUrl.isNotEmpty
                        ? CachedNetworkImage(
                          imageUrl: _currentUrl,
                          fit: BoxFit.cover,
                          errorWidget: (_, _, _) => const _CoverPlaceholder(),
                        )
                        : const _CoverPlaceholder(),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Kachel-Cover',
                    style: TextStyle(
                      fontFamily: 'Nunito',
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _currentUrl.isNotEmpty
                        ? 'Tippe auf eine Folge unten zum Ändern'
                        : 'Wähle das Cover einer Folge',
                    style: const TextStyle(
                      fontFamily: 'Nunito',
                      fontSize: 12,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  if (_currentUrl.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    GestureDetector(
                      onTap: _clearCover,
                      child: const Text(
                        'Entfernen',
                        style: TextStyle(
                          fontFamily: 'Nunito',
                          fontSize: 12,
                          color: AppColors.error,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),

        // Artist image covers
        if (_artistImages.isNotEmpty)
          _coverChipRow('Vom Künstler', _artistImages),

        // Episode cover chips
        if (widget.episodeCovers.isNotEmpty)
          _coverChipRow('Von Folgen', widget.episodeCovers),
      ],
    );
  }

  Widget _coverChipRow(String label, List<String> urls) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: AppSpacing.sm),
        Text(
          label,
          style: const TextStyle(
            fontFamily: 'Nunito',
            fontSize: 11,
            color: AppColors.textSecondary,
          ),
        ),
        const SizedBox(height: 4),
        SizedBox(
          height: 52,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: urls.length,
            separatorBuilder: (_, _) => const SizedBox(width: 6),
            itemBuilder: (context, index) {
              final url = urls[index];
              final isSelected = _currentUrl == url;
              return GestureDetector(
                onTap: () => _pickCover(url),
                child: Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    borderRadius: const BorderRadius.all(AppRadius.card),
                    border:
                        isSelected
                            ? Border.all(color: AppColors.primary, width: 2.5)
                            : null,
                  ),
                  child: ClipRRect(
                    borderRadius: const BorderRadius.all(AppRadius.card),
                    child: CachedNetworkImage(
                      imageUrl: url,
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _CoverPlaceholder extends StatelessWidget {
  const _CoverPlaceholder();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: AppColors.surfaceDim,
      child: Icon(
        Icons.layers_rounded,
        size: 32,
        color: AppColors.textSecondary,
      ),
    );
  }
}

class _EpisodeReorderList extends ConsumerWidget {
  const _EpisodeReorderList({
    required this.tileId,
    required this.episodes,
  });

  final String tileId;
  final List<db.TileItem> episodes;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ReorderableListView.builder(
      padding: const EdgeInsets.only(bottom: AppSpacing.fabClearance),
      buildDefaultDragHandles: false,
      proxyDecorator: (child, index, animation) {
        return AnimatedBuilder(
          animation: animation,
          builder:
              (context, child) => Material(
                elevation: 4,
                shadowColor: Colors.black26,
                borderRadius: const BorderRadius.all(Radius.circular(8)),
                child: child,
              ),
          child: child,
        );
      },
      onReorder: (oldIndex, newIndex) {
        final insertAt = newIndex > oldIndex ? newIndex - 1 : newIndex;
        final reordered = List<db.TileItem>.from(episodes);
        final item = reordered.removeAt(oldIndex);
        reordered.insert(insertAt, item);
        unawaited(
          ref
              .read(tileItemRepositoryProvider)
              .reorder(
                reordered.map((c) => c.id).toList(),
              ),
        );
      },
      itemCount: episodes.length,
      itemBuilder: (context, index) {
        final card = episodes[index];
        return _EpisodeTile(
          key: ValueKey(card.id),
          card: card,
          index: index,
          tileId: tileId,
        );
      },
    );
  }
}

class _EpisodeTile extends ConsumerWidget {
  const _EpisodeTile({
    required this.card,
    required this.index,
    required this.tileId,
    super.key,
  });

  final db.TileItem card;
  final int index;
  final String tileId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      tileColor: AppColors.parentSurface,
      leading: ClipRRect(
        borderRadius: const BorderRadius.all(Radius.circular(6)),
        child: SizedBox(
          width: 40,
          height: 40,
          child:
              card.coverUrl != null
                  ? CachedNetworkImage(
                    imageUrl: card.coverUrl!,
                    fit: BoxFit.cover,
                    memCacheWidth: 80, // 40px @ 2x
                    memCacheHeight: 80,
                    fadeInDuration: Duration.zero,
                    placeholder:
                        (_, _) => const ColoredBox(
                          color: AppColors.surfaceDim,
                        ),
                  )
                  : const ColoredBox(
                    color: AppColors.surfaceDim,
                    child: Icon(Icons.music_note_rounded, size: 20),
                  ),
        ),
      ),
      title: Text(
        card.customTitle ?? card.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          fontFamily: 'Nunito',
          fontWeight: FontWeight.w600,
          fontSize: 14,
        ),
      ),
      subtitle:
          (card.episodeNumber != null || card.isHeard)
              ? Text.rich(
                TextSpan(
                  children: [
                    if (card.episodeNumber != null)
                      TextSpan(
                        text: 'Folge ${card.episodeNumber}',
                        style: const TextStyle(
                          fontFamily: 'Nunito',
                          fontSize: 12,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    if (card.episodeNumber != null && card.isHeard)
                      const TextSpan(text: '  ·  '),
                    if (card.isHeard)
                      const TextSpan(
                        text: '✓ gehört',
                        style: TextStyle(
                          fontFamily: 'Nunito',
                          fontSize: 12,
                          color: AppColors.success,
                        ),
                      ),
                  ],
                ),
              )
              : null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          PopupMenuButton<String>(
            icon: const Icon(
              Icons.more_vert_rounded,
              color: AppColors.textSecondary,
            ),
            onSelected: (action) {
              switch (action) {
                case 'remove':
                  _removeFromGroup(context, ref);
                case 'delete':
                  _deleteCard(context, ref);
              }
            },
            itemBuilder:
                (_) => const [
                  PopupMenuItem(
                    value: 'remove',
                    child: Text('Aus Kachel entfernen'),
                  ),
                  PopupMenuItem(
                    value: 'delete',
                    child: Text(
                      'Eintrag löschen',
                      style: TextStyle(color: AppColors.error),
                    ),
                  ),
                ],
          ),
          ReorderableDragStartListener(
            index: index,
            child: const Icon(
              Icons.drag_handle_rounded,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  void _removeFromGroup(BuildContext context, WidgetRef ref) {
    unawaited(
      showDialog<void>(
        context: context,
        builder:
            (ctx) => AlertDialog(
              title: const Text('Aus Kachel entfernen?'),
              content: Text(
                '„${card.customTitle ?? card.title}" wird aus der Kachel entfernt '
                '(nicht gelöscht).',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Abbrechen'),
                ),
                FilledButton(
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    unawaited(
                      ref
                          .read(tileItemRepositoryProvider)
                          .removeFromTile(card.id),
                    );
                  },
                  child: const Text('Entfernen'),
                ),
              ],
            ),
      ),
    );
  }

  void _deleteCard(BuildContext context, WidgetRef ref) {
    unawaited(
      showDialog<void>(
        context: context,
        builder:
            (ctx) => AlertDialog(
              title: const Text('Eintrag löschen?'),
              content: Text(
                '„${card.customTitle ?? card.title}" wird endgültig gelöscht.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Abbrechen'),
                ),
                FilledButton(
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    unawaited(
                      ref.read(tileItemRepositoryProvider).delete(card.id),
                    );
                  },
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.error,
                  ),
                  child: const Text('Löschen'),
                ),
              ],
            ),
      ),
    );
  }
}

class _EmptyEpisodesHint extends StatelessWidget {
  const _EmptyEpisodesHint();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: AppSpacing.screenH,
          vertical: AppSpacing.md,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.playlist_add_rounded,
              size: 32,
              color: AppColors.textSecondary,
            ),
            SizedBox(height: AppSpacing.sm),
            Text(
              'Tippe auf „Folge hinzufügen" um Folgen hinzuzufügen.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'Nunito',
                fontSize: 13,
                color: AppColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
