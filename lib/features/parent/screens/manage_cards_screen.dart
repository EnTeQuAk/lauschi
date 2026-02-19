import 'dart:async' show unawaited;

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
import 'package:lauschi/core/theme/app_theme.dart';

const _tag = 'ManageCards';

/// Manage existing cards: view, reorder, assign to groups, delete.
class ManageCardsScreen extends ConsumerWidget {
  const ManageCardsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cardsAsync = ref.watch(allCardsProvider);
    final ungroupedCount =
        ref.watch(ungroupedCardsProvider).whenOrNull(data: (c) => c.length) ??
        0;

    return Scaffold(
      backgroundColor: AppColors.parentBackground,
      appBar: AppBar(
        backgroundColor: AppColors.parentBackground,
        title: const Text('Karten verwalten'),
        actions: [
          IconButton(
            onPressed: () => context.push(AppRoutes.parentAddCard),
            icon: const Icon(Icons.add_rounded),
            tooltip: 'Hörspiel hinzufügen',
          ),
        ],
      ),
      body: cardsAsync.when(
        data:
            (cards) =>
                cards.isEmpty
                    ? _EmptyState(
                      onAdd: () => context.push(AppRoutes.parentAddCard),
                    )
                    : Column(
                      children: [
                        if (ungroupedCount > 0)
                          _AutoSortBanner(ungroupedCount: ungroupedCount),
                        Expanded(child: _CardList(cards: cards)),
                      ],
                    ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error:
            (_, _) => const Center(
              child: Text('Fehler beim Laden der Karten.'),
            ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.library_music_rounded,
            size: 48,
            color: AppColors.textSecondary,
          ),
          const SizedBox(height: AppSpacing.md),
          const Text(
            'Noch keine Karten',
            style: TextStyle(
              fontFamily: 'Nunito',
              fontSize: 16,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          FilledButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add_rounded),
            label: const Text('Hörspiel hinzufügen'),
          ),
        ],
      ),
    );
  }
}

class _CardList extends ConsumerWidget {
  const _CardList({required this.cards});

  final List<db.AudioCard> cards;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ReorderableListView.builder(
      padding: const EdgeInsets.only(bottom: AppSpacing.xxl),
      buildDefaultDragHandles: false,
      onReorder: (oldIndex, newIndex) {
        final insertAt = newIndex > oldIndex ? newIndex - 1 : newIndex;
        final reordered = List<db.AudioCard>.from(cards);
        final item = reordered.removeAt(oldIndex);
        reordered.insert(insertAt, item);
        unawaited(
          ref
              .read(cardRepositoryProvider)
              .reorder(
                reordered.map((c) => c.id).toList(),
              ),
        );
      },
      itemCount: cards.length,
      itemBuilder: (context, index) {
        final card = cards[index];
        return _CardTile(
          key: ValueKey(card.id),
          card: card,
          index: index,
          onDelete: () => _confirmDelete(context, ref, card),
          onAssignGroup: () => _showGroupPicker(context, ref, card),
        );
      },
    );
  }

  void _confirmDelete(BuildContext context, WidgetRef ref, db.AudioCard card) {
    unawaited(
      showDialog<void>(
        context: context,
        builder:
            (ctx) => AlertDialog(
              title: const Text('Karte entfernen?'),
              content: Text(
                '„${card.customTitle ?? card.title}" wird aus der Sammlung entfernt.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Abbrechen'),
                ),
                FilledButton(
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    unawaited(ref.read(cardRepositoryProvider).delete(card.id));
                    ScaffoldMessenger.of(context)
                      ..clearSnackBars()
                      ..showSnackBar(
                        SnackBar(
                          content: Text(
                            '${card.customTitle ?? card.title} entfernt',
                          ),
                          duration: const Duration(seconds: 2),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                  },
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.error,
                  ),
                  child: const Text('Entfernen'),
                ),
              ],
            ),
      ),
    );
  }

  void _showGroupPicker(
    BuildContext context,
    WidgetRef ref,
    db.AudioCard card,
  ) {
    unawaited(
      showModalBottomSheet<void>(
        context: context,
        builder: (ctx) => _GroupPickerSheet(card: card),
      ),
    );
  }
}

class _CardTile extends StatelessWidget {
  const _CardTile({
    required this.card,
    required this.index,
    required this.onDelete,
    required this.onAssignGroup,
    super.key,
  });

  final db.AudioCard card;
  final int index;
  final VoidCallback onDelete;
  final VoidCallback onAssignGroup;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      tileColor: AppColors.parentSurface,
      leading: ClipRRect(
        borderRadius: const BorderRadius.all(Radius.circular(6)),
        child: SizedBox(
          width: 48,
          height: 48,
          child:
              card.coverUrl != null
                  ? CachedNetworkImage(
                    imageUrl: card.coverUrl!,
                    fit: BoxFit.cover,
                  )
                  : const ColoredBox(
                    color: AppColors.surfaceDim,
                    child: Icon(Icons.music_note_rounded),
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
          fontSize: 15,
        ),
      ),
      subtitle: Text(
        card.cardType,
        style: const TextStyle(
          fontFamily: 'Nunito',
          fontSize: 13,
          color: AppColors.textSecondary,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            onPressed: onAssignGroup,
            icon: const Icon(Icons.layers_rounded),
            color: AppColors.primary,
            tooltip: 'Serie zuweisen',
          ),
          IconButton(
            onPressed: onDelete,
            icon: const Icon(Icons.delete_outline_rounded),
            color: AppColors.error,
            tooltip: 'Entfernen',
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
}

/// Bottom sheet for picking or removing a group assignment.
class _GroupPickerSheet extends ConsumerWidget {
  const _GroupPickerSheet({required this.card});

  final db.AudioCard card;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groupsAsync = ref.watch(allGroupsProvider);

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
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
          const Padding(
            padding: EdgeInsets.fromLTRB(
              AppSpacing.screenH,
              AppSpacing.sm,
              AppSpacing.screenH,
              AppSpacing.md,
            ),
            child: Text(
              'Serie zuweisen',
              style: TextStyle(
                fontFamily: 'Nunito',
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),

          // Remove from group option (if currently assigned)
          if (card.groupId != null)
            ListTile(
              leading: const Icon(
                Icons.cancel_outlined,
                color: AppColors.textSecondary,
              ),
              title: const Text(
                'Aus Serie entfernen',
                style: TextStyle(fontFamily: 'Nunito'),
              ),
              onTap: () {
                Navigator.of(context).pop();
                unawaited(
                  ref.read(cardRepositoryProvider).removeFromGroup(card.id),
                );
              },
            ),

          // Group list
          groupsAsync.when(
            data:
                (groups) =>
                    groups.isEmpty
                        ? Padding(
                          padding: const EdgeInsets.fromLTRB(
                            AppSpacing.screenH,
                            AppSpacing.sm,
                            AppSpacing.screenH,
                            AppSpacing.lg,
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              const Text(
                                'Noch keine Serien vorhanden.',
                                style: TextStyle(
                                  fontFamily: 'Nunito',
                                  color: AppColors.textSecondary,
                                ),
                              ),
                              const SizedBox(height: AppSpacing.md),
                              FilledButton.icon(
                                onPressed: () {
                                  Navigator.of(context).pop();
                                  unawaited(
                                    context.push(AppRoutes.parentManageGroups),
                                  );
                                },
                                icon: const Icon(Icons.add_rounded),
                                label: const Text('Serie erstellen'),
                              ),
                            ],
                          ),
                        )
                        : ListView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          itemCount: groups.length,
                          itemBuilder: (context, index) {
                            final group = groups[index];
                            final isAssigned = card.groupId == group.id;
                            return ListTile(
                              leading: Icon(
                                Icons.layers_rounded,
                                color:
                                    isAssigned
                                        ? AppColors.primary
                                        : AppColors.textSecondary,
                              ),
                              title: Text(
                                group.title,
                                style: const TextStyle(fontFamily: 'Nunito'),
                              ),
                              trailing:
                                  isAssigned
                                      ? const Icon(
                                        Icons.check_rounded,
                                        color: AppColors.primary,
                                      )
                                      : null,
                              onTap: () {
                                Navigator.of(context).pop();
                                unawaited(
                                  ref
                                      .read(cardRepositoryProvider)
                                      .assignToGroup(
                                        cardId: card.id,
                                        groupId: group.id,
                                      ),
                                );
                              },
                            );
                          },
                        ),
            loading:
                () => const Padding(
                  padding: EdgeInsets.all(AppSpacing.lg),
                  child: CircularProgressIndicator(),
                ),
            error: (_, _) => const SizedBox.shrink(),
          ),

          const SizedBox(height: AppSpacing.md),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Auto-sort banner — shown when ungrouped cards exist
// ---------------------------------------------------------------------------

class _AutoSortBanner extends ConsumerWidget {
  const _AutoSortBanner({required this.ungroupedCount});

  final int ungroupedCount;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      margin: const EdgeInsets.symmetric(
        horizontal: AppSpacing.screenH,
        vertical: AppSpacing.sm,
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
          Icons.auto_awesome_rounded,
          color: AppColors.primary,
          size: 20,
        ),
        title: Text(
          ungroupedCount == 1
              ? '1 Karte ohne Serie'
              : '$ungroupedCount Karten ohne Serie',
          style: const TextStyle(
            fontFamily: 'Nunito',
            fontWeight: FontWeight.w700,
            fontSize: 14,
            color: AppColors.primary,
          ),
        ),
        trailing: FilledButton(
          onPressed: () => unawaited(_runRetroactiveSort(context, ref)),
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.xs,
            ),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: const Text('Einordnen'),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Retroactive series sorting
// ---------------------------------------------------------------------------

/// Runs catalog matching (keyword + stored artist IDs) against all ungrouped
/// cards and assigns matches to their series groups.
///
/// Cards added before schema v4 have no stored artist IDs and fall back to
/// keyword-only matching — albums whose titles omit the series name (e.g.
/// "Folge 38: Eile mit Weile" added in an older build) will not be matched.
Future<void> _runRetroactiveSort(BuildContext context, WidgetRef ref) async {
  final catalog = ref.read(catalogServiceProvider).value;
  if (catalog == null) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        const SnackBar(content: Text('Katalog noch nicht geladen.')),
      );
    return;
  }

  // Show loading dialog
  unawaited(
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder:
          (_) => const AlertDialog(
            content: Row(
              children: [
                CircularProgressIndicator(),
                SizedBox(width: 20),
                Text('Karten werden sortiert…'),
              ],
            ),
          ),
    ),
  );

  try {
    final cardRepo = ref.read(cardRepositoryProvider);
    final groupRepo = ref.read(groupRepositoryProvider);
    final ungrouped = await cardRepo.getUngrouped();

    // Keyword-only match (no artist IDs in stored cards)
    final grouped = <String, String>{}; // seriesTitle → groupId
    var matchCount = 0;

    for (final card in ungrouped) {
      // Parse stored artist IDs so phase-2 matching fires for albums
      // whose titles omit the series name (e.g. "Folge 38: Eile mit Weile").
      final artistIds =
          card.spotifyArtistIds
              ?.split(',')
              .where((s) => s.isNotEmpty)
              .toList() ??
          const [];
      final match = catalog.match(card.title, albumArtistIds: artistIds);
      if (match == null) continue;

      final title = match.series.title;
      if (!grouped.containsKey(title)) {
        final existing = await groupRepo.findByTitle(title);
        grouped[title] = existing?.id ?? await groupRepo.insert(title: title);
      }

      await cardRepo.assignToGroup(
        cardId: card.id,
        groupId: grouped[title]!,
        episodeNumber: match.episodeNumber,
      );
      matchCount++;
    }

    Log.info(
      _tag,
      'Retroactive sort complete',
      data: {
        'ungrouped': ungrouped.length,
        'matched': matchCount,
        'series': grouped.length,
      },
    );

    if (context.mounted) Navigator.of(context).pop(); // close loading dialog

    if (context.mounted) {
      final msg =
          matchCount == 0
              ? 'Keine Karten konnten zugeordnet werden.\n'
                  'Tipp: Karten ohne Serienname im Titel (z.B. „Folge 38: Eile mit Weile") '
                  'müssen manuell einer Serie zugewiesen werden.'
              : '$matchCount Karten zu ${grouped.length} '
                  '${grouped.length == 1 ? 'Serie' : 'Serien'} sortiert.';

      unawaited(
        showDialog<void>(
          context: context,
          builder:
              (_) => AlertDialog(
                title: const Text('Serien einordnen'),
                content: Text(msg),
                actions: [
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('OK'),
                  ),
                ],
              ),
        ),
      );
    }
  } on Exception catch (e) {
    if (context.mounted) Navigator.of(context).pop();
    Log.error(_tag, 'Retroactive sort failed', exception: e);
  }
}
