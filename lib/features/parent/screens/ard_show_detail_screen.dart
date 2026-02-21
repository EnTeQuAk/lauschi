import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lauschi/core/ard/ard_api.dart';
import 'package:lauschi/core/ard/ard_image.dart';
import 'package:lauschi/core/ard/ard_models.dart';
import 'package:lauschi/core/ard/ard_providers.dart';
import 'package:lauschi/core/database/card_repository.dart';
import 'package:lauschi/core/database/content_importer.dart';
import 'package:lauschi/core/theme/app_theme.dart';

/// Multi-part title regex: "Title (1/2)" → groups: title, part, total.
final _multiPartRegex = RegExp(r'^(.+?)\s*\((\d+)/(\d+)\)');

/// Detail screen for an ARD Audiothek show. Lists episodes with
/// options to add individual episodes or all at once.
class ArdShowDetailScreen extends ConsumerStatefulWidget {
  const ArdShowDetailScreen({required this.showId, super.key});

  final String showId;

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

    setState(() => _addingUris.add(item.providerUri));

    try {
      await ref.read(contentImporterProvider.notifier).importToGroup(
        groupTitle: show.title,
        groupCoverUrl: ardImageUrl(show.imageUrl),
        cards: [_ardPendingCard(item)],
      );
    } on Exception catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Fehler: $e')),
        );
        // Clear on error so button re-enables.
        setState(() => _addingUris.remove(item.providerUri));
      }
    }
    // On success: leave in _addingUris — existingCardUrisProvider
    // takes over on next rebuild, preventing double-tap window.
  }

  /// Add all episodes from the show.
  Future<void> _addAll(ArdProgramSet show, List<ArdItem> items) async {
    final importer = ref.read(contentImporterProvider.notifier);

    // Load all pages if needed.
    var allItems = items;
    final page = ref.read(
      ardShowEpisodesProvider(widget.showId),
    ).whenOrNull(data: (d) => d);
    if (page != null && page.hasNextPage) {
      allItems = await _loadAllEpisodes(show.id);
    }

    final playable = allItems.where((i) => i.bestAudioUrl != null).toList();
    final cards = playable.map(_ardPendingCard).toList();

    try {
      final result = await importer.importToGroup(
        groupTitle: show.title,
        groupCoverUrl: ardImageUrl(show.imageUrl),
        cards: cards,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${result.added} Folgen zu ${show.title} hinzugefügt',
            ),
          ),
        );
      }
    } on Exception catch (e) {
      if (mounted) {
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

    return allItems;
  }

  @override
  Widget build(BuildContext context) {
    final existingUris = ref.watch(existingCardUrisProvider);
    final cardsLoaded = ref.watch(allCardsProvider).hasValue;
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
                        final alreadyAdded =
                            existingUris.contains(item.providerUri);
                        final isAdding =
                            _addingUris.contains(item.providerUri);

                        return _EpisodeTile(
                          item: item,
                          alreadyAdded: alreadyAdded,
                          isAdding: isAdding,
                          enabled: cardsLoaded && !isImporting,
                          onAdd: () => _addEpisode(item, show),
                        );
                      },
                      childCount:
                          playable.length + (page.hasNextPage ? 1 : 0),
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
    title: item.title,
    providerUri: item.providerUri,
    cardType: 'episode',
    provider: 'ard_audiothek',
    coverUrl: ardImageUrl(item.imageUrl),
    episodeNumber: item.episodeNumber,
    audioUrl: item.bestAudioUrl,
    durationMs: item.durationMs,
    availableUntil: item.endDate,
  );
}

// ── Show header sliver ──────────────────────────────────────────────────────

class _ShowHeader extends StatelessWidget {
  const _ShowHeader({required this.show});
  final ArdProgramSet show;

  @override
  Widget build(BuildContext context) {
    final imageUrl = ardImageUrl(show.imageUrl, width: 600);

    return SliverAppBar(
      backgroundColor: AppColors.parentBackground,
      expandedHeight: 200,
      pinned: true,
      flexibleSpace: FlexibleSpaceBar(
        title: Text(
          show.title,
          style: const TextStyle(
            fontFamily: 'Nunito',
            fontWeight: FontWeight.w700,
            fontSize: 16,
          ),
        ),
        background:
            imageUrl != null
                ? CachedNetworkImage(
                  imageUrl: imageUrl,
                  fit: BoxFit.cover,
                  color: Colors.black.withAlpha(100),
                  colorBlendMode: BlendMode.darken,
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
  });

  final ArdItem item;
  final bool alreadyAdded;
  final bool isAdding;
  final bool enabled;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final daysLeft = _daysUntilExpiry(item.endDate);
    final multiPart = _multiPartRegex.firstMatch(item.title);

    return ListTile(
      // Uniform leading size: all states use a 24×24 icon inside a
      // fixed 48×48 box to keep text alignment consistent.
      leading: SizedBox(
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
        item.title,
        style: TextStyle(
          fontFamily: 'Nunito',
          fontSize: 14,
          color: alreadyAdded ? AppColors.textSecondary : AppColors.textPrimary,
        ),
      ),
      subtitle: Row(
        children: [
          Text(
            _formatDuration(item.duration),
            style: const TextStyle(
              fontFamily: 'Nunito',
              fontSize: 12,
              color: AppColors.textSecondary,
            ),
          ),
          if (multiPart != null) ...[
            const SizedBox(width: AppSpacing.sm),
            Text(
              'Teil ${multiPart.group(2)}/${multiPart.group(3)}',
              style: const TextStyle(
                fontFamily: 'Nunito',
                fontSize: 12,
                color: AppColors.textSecondary,
              ),
            ),
          ],
          if (daysLeft != null) ...[
            const Spacer(),
            _ExpiryBadge(daysLeft: daysLeft),
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

// ── Expiry badge ────────────────────────────────────────────────────────────

class _ExpiryBadge extends StatelessWidget {
  const _ExpiryBadge({required this.daysLeft});
  final int daysLeft;

  @override
  Widget build(BuildContext context) {
    final color = daysLeft <= 14 ? AppColors.warning : AppColors.textSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: color.withAlpha(25),
        borderRadius: const BorderRadius.all(Radius.circular(4)),
      ),
      child: Text(
        'Noch $daysLeft T.',
        style: TextStyle(
          fontFamily: 'Nunito',
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

// ── Helpers ─────────────────────────────────────────────────────────────────

String _formatDuration(int seconds) {
  final m = seconds ~/ 60;
  if (m < 60) return '$m Min.';
  final h = m ~/ 60;
  final rm = m % 60;
  return '${h}h ${rm}m';
}

int? _daysUntilExpiry(DateTime? endDate) {
  if (endDate == null) return null;
  final days = endDate.difference(DateTime.now()).inDays;
  if (days < 0) return null;
  return days;
}
