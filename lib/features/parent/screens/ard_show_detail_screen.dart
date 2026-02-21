import 'dart:async' show unawaited;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lauschi/core/ard/ard_api.dart';
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
  final _existingUris = <String>{};
  bool _isAddingAll = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadExisting());
  }

  Future<void> _loadExisting() async {
    final cards = await ref.read(cardRepositoryProvider).getAll();
    if (mounted) {
      setState(() {
        _existingUris.addAll(cards.map((c) => c.providerUri));
      });
    }
  }

  /// Add a single episode as a card.
  Future<void> _addEpisode(ArdItem item, {String? groupId}) async {
    final cardRepo = ref.read(cardRepositoryProvider);

    final cardId = await cardRepo.insertIfAbsent(
      title: item.title,
      providerUri: item.providerUri,
      cardType: 'episode',
      provider: 'ard_audiothek',
      coverUrl: _sizedImageUrl(item.imageUrl),
    );

    await cardRepo.updateArdFields(
      cardId: cardId,
      audioUrl: item.bestAudioUrl,
      durationMs: item.durationMs,
      availableUntil: item.endDate,
      groupId: groupId,
      episodeNumber: item.episodeNumber,
    );

    if (mounted) {
      setState(() => _existingUris.add(item.providerUri));
    }

    Log.info(_tag, 'Added episode', data: {'title': item.title});
  }

  /// Add all episodes from the show, creating a group.
  Future<void> _addAll(ArdProgramSet show, List<ArdItem> items) async {
    if (_isAddingAll) return;
    setState(() => _isAddingAll = true);

    try {
      final groups = ref.read(groupRepositoryProvider);

      // Find or create group.
      final existing = await groups.findByTitle(show.title);
      final groupId =
          existing?.id ??
          await groups.insert(
            title: show.title,
            coverUrl: _sizedImageUrl(show.imageUrl),
          );

      // Update group with ARD provider info.
      await groups.update(
        id: groupId,
        coverUrl: _sizedImageUrl(show.imageUrl),
      );

      var added = 0;
      for (final item in items) {
        if (_existingUris.contains(item.providerUri)) continue;
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

  @override
  Widget build(BuildContext context) {
    final showAsync = ref.watch(_showDetailProvider(widget.showId));
    final episodesAsync = ref.watch(_showEpisodesProvider(widget.showId));

    return Scaffold(
      backgroundColor: AppColors.parentBackground,
      body: showAsync.when(
        loading:
            () => const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            ),
        error:
            (e, _) => Scaffold(
              appBar: AppBar(),
              body: Center(child: Text('Fehler: $e')),
            ),
        data: (show) {
          if (show == null) {
            return Scaffold(
              appBar: AppBar(),
              body: const Center(child: Text('Sendung nicht gefunden.')),
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
                data:
                    (page) => SliverList(
                      delegate: SliverChildBuilderDelegate(
                        (context, index) {
                          final item = page.items[index];
                          final alreadyAdded =
                              _existingUris.contains(item.providerUri);
                          return _EpisodeTile(
                            item: item,
                            alreadyAdded: alreadyAdded,
                            onAdd: () => _addEpisode(item),
                          );
                        },
                        childCount: page.items.length,
                      ),
                    ),
              ),
            ],
          );
        },
      ),
      bottomNavigationBar: _buildAddAllBar(showAsync, episodesAsync),
    );
  }

  Widget? _buildAddAllBar(
    AsyncValue<ArdProgramSet?> showAsync,
    AsyncValue<ArdItemPage> episodesAsync,
  ) {
    final show = showAsync.whenOrNull(data: (d) => d);
    final episodes = episodesAsync.whenOrNull(data: (d) => d.items);
    if (show == null || episodes == null || episodes.isEmpty) return null;

    final addable =
        episodes.where((e) => !_existingUris.contains(e.providerUri)).length;
    if (addable == 0) return null;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: FilledButton.icon(
          onPressed: _isAddingAll ? null : () => _addAll(show, episodes),
          icon:
              _isAddingAll
                  ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                  : const Icon(Icons.add_rounded),
          label: Text(
            '$addable Folgen hinzufügen',
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
    final imageUrl = _sizedImageUrl(show.imageUrl, width: 600);

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
    required this.onAdd,
  });

  final ArdItem item;
  final bool alreadyAdded;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final daysLeft = _daysUntilExpiry(item.endDate);
    final multiPart = _multiPartRegex.firstMatch(item.title);

    return ListTile(
      leading:
          alreadyAdded
              ? const Icon(Icons.check_circle, color: AppColors.success)
              : IconButton(
                icon: const Icon(Icons.add_circle_outline_rounded),
                onPressed: onAdd,
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
      enabled: !alreadyAdded,
      onTap: alreadyAdded ? null : onAdd,
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

String? _sizedImageUrl(String? url, {int width = 400}) {
  if (url == null) return null;
  return url.replaceAll('{width}', '$width');
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
