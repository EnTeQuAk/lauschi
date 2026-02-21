import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lauschi/core/ard/ard_api.dart';
import 'package:lauschi/core/ard/ard_image.dart';
import 'package:lauschi/core/ard/ard_models.dart';
import 'package:lauschi/core/database/card_repository.dart';
import 'package:lauschi/core/database/group_repository.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/theme/app_theme.dart';

const _tag = 'ArdShowDetail';

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
  final _addingUris = <String>{};
  bool _isAddingAll = false;

  /// Add a single episode as a card.
  Future<void> _addEpisode(ArdItem item, {String? groupId}) async {
    if (item.bestAudioUrl == null) return;
    if (_addingUris.contains(item.providerUri)) return;

    setState(() => _addingUris.add(item.providerUri));

    try {
      final cardRepo = ref.read(cardRepositoryProvider);

      await cardRepo.insertArdEpisode(
        title: item.title,
        providerUri: item.providerUri,
        audioUrl: item.bestAudioUrl!,
        coverUrl: ardImageUrl(item.imageUrl),
        durationMs: item.durationMs,
        availableUntil: item.endDate,
        groupId: groupId,
        episodeNumber: item.episodeNumber,
      );

      // No manual _existingUris.add() — the Drift stream backing
      // existingCardUrisProvider updates automatically on insert.

      Log.info(_tag, 'Added episode', data: {'title': item.title});
    } on Exception catch (e) {
      Log.error(_tag, 'Failed to add episode', exception: e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Fehler: $e')),
        );
        // Only clear adding state on error — on success, the URI stays in
        // _addingUris until the Drift stream updates existingCardUrisProvider.
        // This prevents a double-tap window between insert and stream emission.
        setState(() => _addingUris.remove(item.providerUri));
      }
    }
  }

  /// Add all episodes from the show, creating a group.
  /// Also assigns already-added episodes to the group.
  Future<void> _addAll(ArdProgramSet show, List<ArdItem> items) async {
    if (_isAddingAll) return;
    setState(() => _isAddingAll = true);

    try {
      final groups = ref.read(groupRepositoryProvider);
      final cardRepo = ref.read(cardRepositoryProvider);

      // Find or create group.
      final existing = await groups.findByTitle(show.title);
      final groupId =
          existing?.id ??
          await groups.insert(
            title: show.title,
            coverUrl: ardImageUrl(show.imageUrl),
          );

      // Update group cover.
      await groups.update(
        id: groupId,
        coverUrl: ardImageUrl(show.imageUrl),
      );

      // Load all pages if the first page indicated more exist.
      var allItems = items;
      final episodesPage = ref.read(_showEpisodesProvider(widget.showId));
      final page = episodesPage.whenOrNull(data: (d) => d);
      if (page != null && page.hasNextPage) {
        allItems = await _loadAllEpisodes(show.id);
      }

      var added = 0;
      for (final item in allItems) {
        if (item.bestAudioUrl == null) continue;

        if (ref.read(existingCardUrisProvider).contains(item.providerUri)) {
          // Already added — assign to group if not already.
          final card = await cardRepo.getByProviderUri(item.providerUri);
          if (card != null && card.groupId != groupId) {
            await cardRepo.updateArdFields(
              cardId: card.id,
              groupId: groupId,
              episodeNumber: item.episodeNumber,
            );
          }
          continue;
        }

        await _addEpisode(item, groupId: groupId);
        added++;
      }

      Log.info(
        _tag,
        'Added all episodes',
        data: {'show': show.title, 'added': '$added'},
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('$added Folgen zu ${show.title} hinzugefügt'),
          ),
        );
      }
    } on Exception catch (e) {
      Log.error(_tag, 'Failed to add all', exception: e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Fehler: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isAddingAll = false);
    }
  }

  /// Load all episode pages for a show.
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
    final showAsync = ref.watch(_showDetailProvider(widget.showId));
    final episodesAsync = ref.watch(_showEpisodesProvider(widget.showId));

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
                  final items = page.items;
                  final playable =
                      items.where((i) => i.bestAudioUrl != null).toList();

                  return SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, index) {
                        // Show truncation notice at the end.
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
                          enabled: cardsLoaded && !_isAddingAll,
                          onAdd: () => _addEpisode(item),
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
        showAsync,
        episodesAsync,
        existingUris: existingUris,
        cardsLoaded: cardsLoaded,
      ),
    );
  }

  Widget? _buildAddAllBar(
    AsyncValue<ArdProgramSet?> showAsync,
    AsyncValue<ArdItemPage> episodesAsync, {
    required Set<String> existingUris,
    required bool cardsLoaded,
  }) {
    final show = showAsync.whenOrNull(data: (d) => d);
    final page = episodesAsync.whenOrNull(data: (d) => d);
    if (show == null || page == null || page.items.isEmpty) return null;
    if (!cardsLoaded) return null;

    final playable = page.items.where((i) => i.bestAudioUrl != null);
    final addable =
        playable.where((e) => !existingUris.contains(e.providerUri)).length;

    // Use totalCount from API when there are more pages.
    final totalLabel =
        page.hasNextPage ? 'Alle ${page.totalCount}' : '$addable';

    if (addable == 0 && !page.hasNextPage) return null;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: FilledButton.icon(
          onPressed:
              _isAddingAll
                  ? null
                  : () => _addAll(show, page.items),
          icon:
              _isAddingAll
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
      leading:
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
  if (days < 0) return null; // Already expired
  return days;
}

// ── Providers ───────────────────────────────────────────────────────────────

final _showDetailProvider =
    FutureProvider.autoDispose.family<ArdProgramSet?, String>(
  (ref, showId) => ref.watch(ardApiProvider).getProgramSet(showId),
);

final _showEpisodesProvider =
    FutureProvider.autoDispose.family<ArdItemPage, String>(
  (ref, showId) => ref.watch(ardApiProvider).getItems(programSetId: showId),
);
