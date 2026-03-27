import 'dart:async' show unawaited;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lauschi/core/ard/ard_api.dart';
import 'package:lauschi/core/ard/ard_helpers.dart';
import 'package:lauschi/core/ard/ard_image.dart';
import 'package:lauschi/core/ard/ard_models.dart';
import 'package:lauschi/core/ard/ard_providers.dart';
import 'package:lauschi/core/database/content_importer.dart';
import 'package:lauschi/core/database/tile_item_repository.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/providers/provider_type.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/parent/widgets/import_progress_dialog.dart';

const _tag = 'ArdShowDetailScreen';

// Multi-part grouping is now handled via item.group from the API.

/// Detail screen for an ARD Audiothek show. Lists episodes with
/// options to add individual episodes or all at once.
///
/// When [autoAssignTileId] is set, episodes are added directly to
/// that tile instead of creating a group by show title.
class ArdShowDetailScreen extends ConsumerStatefulWidget {
  const ArdShowDetailScreen({
    required this.showId,
    super.key,
    this.autoAssignTileId,
  });

  final String showId;
  final String? autoAssignTileId;

  @override
  ConsumerState<ArdShowDetailScreen> createState() =>
      _ArdShowDetailScreenState();
}

class _ArdShowDetailScreenState extends ConsumerState<ArdShowDetailScreen> {
  /// Per-item UI loading state. Tracks which episodes have an in-flight import.
  /// This is UI state (which button shows a spinner), not domain state.
  final _addingUris = <String>{};

  /// Add a single episode, auto-grouping under the show title.
  Future<void> _addEpisode(ArdItem item, ArdProgramSet show) async {
    if (item.bestAudioUrl == null) return;
    if (_addingUris.contains(item.providerUri)) return;

    Log.info(
      _tag,
      'Adding episode',
      data: {
        'showId': show.id,
        'episodeUri': item.providerUri,
        'title': item.displayTitle,
      },
    );
    setState(() => _addingUris.add(item.providerUri));

    try {
      await ref
          .read(contentImporterProvider.notifier)
          .importToGroup(
            groupTitle: show.title,
            groupCoverUrl: ardImageUrl(show.imageUrl),
            cards: [_ardPendingCard(item)],
            tileId: widget.autoAssignTileId,
          );
    } on Exception catch (e) {
      Log.error(
        _tag,
        'Add episode failed',
        exception: e,
        data: {
          'episodeUri': item.providerUri,
        },
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Fehler: $e')),
        );
        // Clear on error so button re-enables.
        setState(() => _addingUris.remove(item.providerUri));
      }
    }
    // On success: leave in _addingUris — existingItemUrisProvider
    // takes over on next rebuild, preventing double-tap window.
  }

  /// Add all episodes from the show.
  Future<void> _addAll(ArdProgramSet show, List<ArdItem> items) async {
    Log.info(
      _tag,
      'Adding all episodes',
      data: {
        'showId': show.id,
        'showTitle': show.title,
      },
    );

    final statusNotifier = ValueNotifier<String>('Lade ${show.title}…');
    final progressNotifier = ValueNotifier<(int, int)>((0, 0));

    if (mounted) {
      unawaited(
        showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder:
              (_) => ImportProgressDialog(
                status: statusNotifier,
                progress: progressNotifier,
              ),
        ),
      );
    }

    try {
      // Load all pages if needed.
      var allItems = items;
      final page = ref
          .read(ardShowEpisodesProvider(widget.showId))
          .whenOrNull(data: (d) => d);
      if (page != null && page.hasNextPage) {
        allItems = await _loadAllEpisodes(show.id);
      }

      final playable = allItems.where((i) => i.bestAudioUrl != null).toList();
      final cards = playable.map(_ardPendingCard).toList();
      progressNotifier.value = (0, cards.length);
      statusNotifier.value = 'Speichere ${show.title}…';

      final importer = ref.read(contentImporterProvider.notifier);
      final result = await importer.importToGroup(
        groupTitle: show.title,
        groupCoverUrl: ardImageUrl(show.imageUrl),
        cards: cards,
        tileId: widget.autoAssignTileId,
        onProgress: (done, total) => progressNotifier.value = (done, total),
      );

      Log.info(
        _tag,
        'All episodes added',
        data: {
          'showId': show.id,
          'added': '${result.added}',
          'total': '${playable.length}',
        },
      );

      if (mounted) {
        Navigator.of(context).pop(); // dismiss dialog
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${result.added} Folgen zu ${show.title} hinzugefügt',
            ),
          ),
        );
      }
    } on Exception catch (e) {
      Log.error(
        _tag,
        'Add all failed',
        exception: e,
        data: {'showId': show.id},
      );
      if (mounted) {
        Navigator.of(context).pop(); // dismiss dialog
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Fehler: $e')),
        );
      }
    }
  }

  Future<List<ArdItem>> _loadAllEpisodes(String showId) async {
    final api = ref.read(ardApiProvider);
    final allItems = <ArdItem>[];
    String? cursor;

    do {
      final page = await api.getItems(
        programSetId: showId,
        after: cursor,
      );
      allItems.addAll(page.items);
      cursor = page.hasNextPage ? page.endCursor : null;
    } while (cursor != null);

    Log.debug(
      _tag,
      'All episodes loaded',
      data: {
        'showId': showId,
        'total': '${allItems.length}',
      },
    );
    return allItems;
  }

  @override
  Widget build(BuildContext context) {
    final existingUris = ref.watch(existingItemUrisProvider);
    final cardsLoaded = ref.watch(allTileItemsProvider).hasValue;
    final isImporting = ref.watch(contentImporterProvider);
    final showAsync = ref.watch(ardShowDetailProvider(widget.showId));
    final episodesAsync = ref.watch(ardShowEpisodesProvider(widget.showId));

    return Scaffold(
      backgroundColor: AppColors.parentBackground,
      body: showAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error:
            (e, _) => Column(
              children: [
                AppBar(backgroundColor: AppColors.parentBackground),
                Expanded(child: Center(child: Text('Fehler: $e'))),
              ],
            ),
        data: (show) {
          if (show == null) {
            return Column(
              children: [
                AppBar(
                  backgroundColor: AppColors.parentBackground,
                  title: const Text('Nicht gefunden'),
                ),
                const Expanded(
                  child: Center(child: Text('Sendung nicht gefunden.')),
                ),
              ],
            );
          }

          return CustomScrollView(
            slivers: [
              _ShowHeader(show: show),

              // Synopsis and duration badge between header and episodes.
              SliverToBoxAdapter(
                child: _ShowMeta(
                  show: show,
                  episodesAsync: episodesAsync,
                ),
              ),

              episodesAsync.when(
                loading:
                    () => const SliverFillRemaining(
                      child: Center(child: CircularProgressIndicator()),
                    ),
                error:
                    (e, _) => SliverFillRemaining(
                      child: Center(child: Text('Fehler: $e')),
                    ),
                data: (page) {
                  final playable =
                      page.items.where((i) => i.bestAudioUrl != null).toList();

                  return SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, index) {
                        if (index == playable.length && page.hasNextPage) {
                          return _TruncationNotice(
                            shown: playable.length,
                            total: page.totalCount,
                          );
                        }

                        final item = playable[index];
                        final alreadyAdded = existingUris.contains(
                          item.providerUri,
                        );
                        final isAdding = _addingUris.contains(item.providerUri);

                        return _EpisodeTile(
                          item: item,
                          alreadyAdded: alreadyAdded,
                          isAdding: isAdding,
                          enabled: cardsLoaded && !isImporting,
                          onAdd: () => _addEpisode(item, show),
                          showImageUrl: show.imageUrl,
                        );
                      },
                      childCount: playable.length + (page.hasNextPage ? 1 : 0),
                    ),
                  );
                },
              ),
            ],
          );
        },
      ),
      bottomNavigationBar: _buildAddAllBar(
        showAsync: showAsync,
        episodesAsync: episodesAsync,
        existingUris: existingUris,
        cardsLoaded: cardsLoaded,
        isImporting: isImporting,
      ),
    );
  }

  Widget? _buildAddAllBar({
    required AsyncValue<ArdProgramSet?> showAsync,
    required AsyncValue<ArdItemPage> episodesAsync,
    required Set<String> existingUris,
    required bool cardsLoaded,
    required bool isImporting,
  }) {
    final show = showAsync.whenOrNull(data: (d) => d);
    final page = episodesAsync.whenOrNull(data: (d) => d);
    if (show == null || page == null || page.items.isEmpty) return null;
    if (!cardsLoaded) return null;

    final playable = page.items.where((i) => i.bestAudioUrl != null);
    final addable =
        playable.where((e) => !existingUris.contains(e.providerUri)).length;

    final totalLabel =
        page.hasNextPage ? 'Alle ${page.totalCount}' : '$addable';

    if (addable == 0 && !page.hasNextPage) return null;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: FilledButton.icon(
          key: const Key('add_all_episodes'),
          onPressed: isImporting ? null : () => _addAll(show, page.items),
          icon:
              isImporting
                  ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                  : const Icon(Icons.add_rounded),
          label: Text(
            '$totalLabel Folgen hinzufügen',
            style: const TextStyle(fontFamily: 'Nunito'),
          ),
        ),
      ),
    );
  }
}

/// Build a [PendingCard] from an ARD episode.
PendingCard _ardPendingCard(ArdItem item) {
  return PendingCard(
    title: item.displayTitle,
    providerUri: item.providerUri,
    cardType: 'episode',
    provider: ProviderType.ardAudiothek,
    coverUrl: ardImageUrl(item.imageUrl),
    episodeNumber: item.episodeNumber,
    audioUrl: item.bestAudioUrl,
    durationMs: item.durationMs,
  );
}

// ── Show header sliver ──────────────────────────────────────────────────────

class _ShowHeader extends StatelessWidget {
  const _ShowHeader({required this.show});
  final ArdProgramSet show;

  @override
  Widget build(BuildContext context) {
    final imageUrl = ardImageUrl(show.imageUrl, width: 600);
    final subtitle = show.organizationName ?? show.publisher;

    return SliverAppBar(
      backgroundColor: AppColors.parentBackground,
      expandedHeight: 200,
      pinned: true,
      foregroundColor: Colors.white,
      iconTheme: const IconThemeData(
        color: Colors.white,
        shadows: [Shadow(blurRadius: 8)],
      ),
      flexibleSpace: FlexibleSpaceBar(
        title: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              show.title,
              style: const TextStyle(
                fontFamily: 'Nunito',
                fontWeight: FontWeight.w700,
                fontSize: 16,
                color: Colors.white,
                shadows: [
                  Shadow(blurRadius: 12),
                  Shadow(blurRadius: 4),
                ],
              ),
            ),
            if (subtitle != null)
              Text(
                '$subtitle · ${show.numberOfElements} Folgen',
                style: const TextStyle(
                  fontFamily: 'Nunito',
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: Colors.white,
                  shadows: [
                    Shadow(blurRadius: 12),
                    Shadow(blurRadius: 4),
                  ],
                ),
              ),
          ],
        ),
        background:
            imageUrl != null
                ? Stack(
                  fit: StackFit.expand,
                  children: [
                    CachedNetworkImage(
                      imageUrl: imageUrl,
                      fit: BoxFit.cover,
                    ),
                    // Gradient overlay: dark top for readability, publisher
                    // color bloom at the bottom behind the title text.
                    DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          stops: const [0.0, 0.3, 0.65, 1.0],
                          colors: [
                            Colors.black.withAlpha(60),
                            Colors.black.withAlpha(20),
                            Colors.black.withAlpha(200),
                            Colors.black,
                          ],
                        ),
                      ),
                    ),
                  ],
                )
                : null,
      ),
    );
  }
}

// ── Episode tile ────────────────────────────────────────────────────────────

class _EpisodeTile extends StatelessWidget {
  const _EpisodeTile({
    required this.item,
    required this.alreadyAdded,
    required this.isAdding,
    required this.enabled,
    required this.onAdd,
    this.showImageUrl,
  });

  final ArdItem item;
  final bool alreadyAdded;
  final bool isAdding;
  final bool enabled;
  final VoidCallback onAdd;

  /// Fallback image when the episode has no unique artwork.
  final String? showImageUrl;

  @override
  Widget build(BuildContext context) {
    final episodeImageUrl = ardImageUrl(item.imageUrl, width: 112);
    final fallbackUrl = ardImageUrl(showImageUrl, width: 112);

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.screenH,
        vertical: 2,
      ),
      // Leading: episode artwork thumbnail.
      leading: ClipRRect(
        borderRadius: const BorderRadius.all(Radius.circular(8)),
        child: SizedBox(
          width: 56,
          height: 56,
          child: CachedNetworkImage(
            imageUrl: episodeImageUrl ?? fallbackUrl ?? '',
            fit: BoxFit.cover,
            placeholder:
                (_, _) => ColoredBox(
                  color: AppColors.surfaceDim,
                  child: Center(
                    child: Text(
                      item.episodeNumber?.toString() ?? '',
                      style: const TextStyle(
                        fontFamily: 'Nunito',
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                ),
            errorWidget:
                (_, _, _) => const ColoredBox(
                  color: AppColors.surfaceDim,
                  child: Center(
                    child: Icon(
                      Icons.headphones_rounded,
                      size: 20,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
          ),
        ),
      ),
      // Trailing: add/check/spinner action.
      trailing: SizedBox(
        width: 48,
        height: 48,
        child: Center(
          child:
              alreadyAdded
                  ? const Icon(Icons.check_circle, color: AppColors.success)
                  : isAdding
                  ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                  : IconButton(
                    icon: const Icon(Icons.add_circle_outline_rounded),
                    onPressed: enabled ? onAdd : null,
                    padding: EdgeInsets.zero,
                  ),
        ),
      ),
      title: Text(
        item.displayTitle,
        style: TextStyle(
          fontFamily: 'Nunito',
          fontSize: 14,
          color: alreadyAdded ? AppColors.textSecondary : AppColors.textPrimary,
        ),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Row(
        children: [
          Text(
            formatDuration(item.duration),
            style: const TextStyle(
              fontFamily: 'Nunito',
              fontSize: 12,
              color: AppColors.textSecondary,
            ),
          ),
          if (item.group != null) ...[
            const SizedBox(width: AppSpacing.sm),
            Text(
              'Teil ${item.episodeNumber ?? "?"}/${item.group!.count ?? "?"}',
              style: const TextStyle(
                fontFamily: 'Nunito',
                fontSize: 12,
                color: AppColors.textSecondary,
              ),
            ),
          ],
        ],
      ),
      enabled: enabled && !alreadyAdded && !isAdding,
      onTap: enabled && !alreadyAdded && !isAdding ? onAdd : null,
    );
  }
}

// ── Truncation notice ───────────────────────────────────────────────────────

class _TruncationNotice extends StatelessWidget {
  const _TruncationNotice({required this.shown, required this.total});
  final int shown;
  final int total;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Text(
        '$shown von $total Folgen angezeigt. '
        'Über „Alle hinzufügen" werden alle Folgen geladen.',
        style: const TextStyle(
          fontFamily: 'Nunito',
          fontSize: 12,
          color: AppColors.textSecondary,
        ),
        textAlign: TextAlign.center,
      ),
    );
  }
}

// ── Show metadata (synopsis + duration badge) ──────────────────────────────

/// Duration category with icon and label.
({IconData icon, String label}) _durationCategory(int avgSeconds) {
  final minutes = avgSeconds ~/ 60;
  if (minutes <= 6) {
    return (icon: Icons.nightlight_round, label: '~$minutes Min.');
  } else if (minutes <= 20) {
    return (icon: Icons.menu_book_rounded, label: '~$minutes Min.');
  } else if (minutes <= 35) {
    return (icon: Icons.theater_comedy_rounded, label: '~$minutes Min.');
  } else {
    return (icon: Icons.headphones_rounded, label: '~$minutes Min.');
  }
}

class _ShowMeta extends StatelessWidget {
  const _ShowMeta({required this.show, required this.episodesAsync});

  final ArdProgramSet show;
  final AsyncValue<ArdItemPage> episodesAsync;

  @override
  Widget build(BuildContext context) {
    final synopsis = show.synopsis;

    // Compute avg duration from loaded episodes.
    final avgDuration = episodesAsync.whenOrNull(
      data: (page) {
        final playable = page.items.where((i) => i.bestAudioUrl != null);
        if (playable.isEmpty) return null;
        final total = playable.fold<int>(0, (sum, i) => sum + i.duration);
        return total ~/ playable.length;
      },
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.screenH,
        AppSpacing.md,
        AppSpacing.screenH,
        AppSpacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Duration badge
          if (avgDuration != null && avgDuration > 0) ...[
            () {
              final cat = _durationCategory(avgDuration);
              return Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.sm,
                  vertical: 3,
                ),
                decoration: const BoxDecoration(
                  color: AppColors.surfaceDim,
                  borderRadius: BorderRadius.all(Radius.circular(6)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(cat.icon, size: 14, color: AppColors.textSecondary),
                    const SizedBox(width: 4),
                    Text(
                      cat.label,
                      style: const TextStyle(
                        fontFamily: 'Nunito',
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              );
            }(),
            const SizedBox(height: AppSpacing.sm),
          ],
          // Synopsis
          if (synopsis != null && synopsis.isNotEmpty)
            Text(
              synopsis,
              style: const TextStyle(
                fontFamily: 'Nunito',
                fontSize: 13,
                color: AppColors.textSecondary,
                height: 1.4,
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
        ],
      ),
    );
  }
}
