import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lauschi/core/ard/ard_image.dart';
import 'package:lauschi/core/ard/ard_models.dart';
import 'package:lauschi/core/ard/ard_providers.dart';
import 'package:lauschi/core/database/content_importer.dart';
import 'package:lauschi/core/database/tile_item_repository.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/providers/provider_type.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/parent/screens/ard_show_detail/widgets/ard_episode_tile.dart';
import 'package:lauschi/features/parent/screens/ard_show_detail/widgets/ard_show_header.dart';
import 'package:lauschi/features/parent/screens/ard_show_detail/widgets/ard_show_meta.dart';

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

  /// Add all episodes from the show via the provider-based importer.
  void _addAll(ArdProgramSet show, List<ArdItem> items) {
    if (ref.read(contentImporterProvider).isImporting) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Import läuft bereits.')),
      );
      return;
    }

    final page = ref
        .read(ardShowEpisodesProvider(widget.showId))
        .whenOrNull(data: (d) => d);

    unawaited(
      ref
          .read(contentImporterProvider.notifier)
          .importArdShow(
            showId: show.id,
            showTitle: show.title,
            showImageUrl: show.imageUrl,
            loadedItems: items,
            hasMorePages: page?.hasNextPage ?? false,
            endCursor: page?.endCursor,
            tileId: widget.autoAssignTileId,
          ),
    );
  }

  bool _dialogShowing = false;

  void _dismissDialog() {
    if (_dialogShowing) {
      Navigator.of(context).pop();
      _dialogShowing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final existingUris = ref.watch(existingItemUrisProvider);
    final cardsLoaded = ref.watch(allTileItemsProvider).hasValue;
    final isImporting = ref.watch(
      contentImporterProvider.select((s) => s.isImporting),
    );
    final showAsync = ref.watch(ardShowDetailProvider(widget.showId));
    final episodesAsync = ref.watch(ardShowEpisodesProvider(widget.showId));

    ref.listen(contentImporterProvider, (_, next) {
      switch (next) {
        case ImportRunning() when !_dialogShowing:
          _dialogShowing = true;
          unawaited(
            showDialog<void>(
              context: context,
              barrierDismissible: false,
              builder: (_) => _ImportDialogView(),
            ).then((_) => _dialogShowing = false),
          );
        case ImportDone(:final added, :final showTitle):
          _dismissDialog();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('$added Folgen zu $showTitle hinzugefügt')),
          );
          ref.read(contentImporterProvider.notifier).acknowledge();
        case ImportFailed(:final message):
          _dismissDialog();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Fehler: $message')),
          );
          ref.read(contentImporterProvider.notifier).acknowledge();
        case _:
          break;
      }
    });

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
              ArdShowHeader(show: show),

              // Synopsis and duration badge between header and episodes.
              SliverToBoxAdapter(
                child: ArdShowMeta(
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

                        return ArdEpisodeTile(
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

// ── Inline widgets ──────────────────────────────────────────────────────

/// Import progress dialog that watches the provider for live updates.
/// Lives outside the triggering widget's lifecycle.
class _ImportDialogView extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(contentImporterProvider);
    final status = state is ImportRunning ? state.status : '';
    final done = state is ImportRunning ? state.done : 0;
    final total = state is ImportRunning ? state.total : 0;

    return PopScope(
      canPop: false,
      child: Dialog(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                status,
                style: const TextStyle(
                  fontFamily: 'Nunito',
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              if (total == 0)
                const LinearProgressIndicator(
                  minHeight: 6,
                  backgroundColor: AppColors.surfaceDim,
                  valueColor: AlwaysStoppedAnimation<Color>(AppColors.primary),
                )
              else
                Column(
                  children: [
                    ClipRRect(
                      borderRadius: const BorderRadius.all(AppRadius.pill),
                      child: LinearProgressIndicator(
                        value: done / total,
                        minHeight: 6,
                        backgroundColor: AppColors.surfaceDim,
                        valueColor: const AlwaysStoppedAnimation<Color>(
                          AppColors.primary,
                        ),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    Text(
                      '$done von $total',
                      style: const TextStyle(
                        fontFamily: 'Nunito',
                        fontSize: 13,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

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
