import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lauschi/core/catalog/catalog_service.dart';
import 'package:lauschi/core/catalog/retroactive_sorter.dart';
import 'package:lauschi/core/database/app_database.dart' as db;
import 'package:lauschi/core/database/tile_item_repository.dart';
import 'package:lauschi/core/database/tile_repository.dart';
import 'package:lauschi/core/feature_flags.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/router/app_router.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/parent/screens/manage_cards/widgets/auto_sort_banner.dart';
import 'package:lauschi/features/parent/screens/manage_cards/widgets/card_section_header.dart';
import 'package:lauschi/features/parent/screens/manage_cards/widgets/card_tile.dart';
import 'package:lauschi/features/parent/screens/manage_cards/widgets/group_picker_sheet.dart';
import 'package:lauschi/features/parent/screens/manage_cards/widgets/sort_result_dialog.dart';

const _tag = 'ManageCards';

/// All cards grouped by their series. Ungrouped cards in a separate section.
class ManageCardsScreen extends ConsumerWidget {
  const ManageCardsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groupsAsync = ref.watch(allTilesProvider);
    final ungroupedAsync = ref.watch(ungroupedItemsProvider);
    final totalCards =
        ref.watch(allTileItemsProvider).whenOrNull(data: (c) => c.length) ?? 0;

    return Scaffold(
      backgroundColor: AppColors.parentBackground,
      appBar: AppBar(
        backgroundColor: AppColors.parentBackground,
        title: const Text('Karten verwalten'),
        actions: [
          IconButton(
            key: const Key('add_card_button'),
            onPressed:
                () => context.push(
                  FeatureFlags.enableSpotify
                      ? AppRoutes.parentCatalog
                      : AppRoutes.parentAddContent,
                ),
            icon: const Icon(Icons.add_rounded),
            tooltip: 'Hörspiel hinzufügen',
          ),
        ],
      ),
      body:
          totalCards == 0
              ? _EmptyState(
                onAdd:
                    () => context.push(
                      FeatureFlags.enableSpotify
                          ? AppRoutes.parentCatalog
                          : AppRoutes.parentAddContent,
                    ),
              )
              : _GroupedCardList(
                groupsAsync: groupsAsync,
                ungroupedAsync: ungroupedAsync,
              ),
    );
  }
}

// ---------------------------------------------------------------------------
// Main list: series sections + ungrouped section
// ---------------------------------------------------------------------------

class _GroupedCardList extends ConsumerStatefulWidget {
  const _GroupedCardList({
    required this.groupsAsync,
    required this.ungroupedAsync,
  });

  final AsyncValue<List<db.Tile>> groupsAsync;
  final AsyncValue<List<db.TileItem>> ungroupedAsync;

  @override
  ConsumerState<_GroupedCardList> createState() => _GroupedCardListState();
}

class _GroupedCardListState extends ConsumerState<_GroupedCardList> {
  final _ungroupedKey = GlobalKey();

  void _scrollToUngrouped() {
    final ctx = _ungroupedKey.currentContext;
    if (ctx != null) {
      unawaited(
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final groups = widget.groupsAsync.whenOrNull(data: (g) => g) ?? [];
    final ungrouped = widget.ungroupedAsync.whenOrNull(data: (c) => c) ?? [];

    return CustomScrollView(
      slivers: [
        if (ungrouped.isNotEmpty)
          SliverToBoxAdapter(
            child: AutoSortBanner(
              ungroupedCount: ungrouped.length,
              onSort: () => unawaited(_runRetroactiveSort(context, ref)),
              onTap: _scrollToUngrouped,
            ),
          ),

        for (final group in groups) _GroupSection(group: group),

        if (ungrouped.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: CardSectionHeader(
              key: _ungroupedKey,
              title: 'Nicht zugeordnet',
              subtitle: '${ungrouped.length} Karten',
              icon: Icons.layers_clear_rounded,
            ),
          ),
          SliverList.builder(
            itemCount: ungrouped.length,
            itemBuilder:
                (context, index) => CardTile(
                  card: ungrouped[index],
                  showGroupAssign: true,
                  onAssignGroup:
                      () => _showGroupPicker(context, ref, ungrouped[index]),
                  onDelete:
                      () => _confirmDelete(context, ref, ungrouped[index]),
                ),
          ),
        ],

        const SliverPadding(padding: EdgeInsets.only(bottom: AppSpacing.xxl)),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Series section: header + episode list
// ---------------------------------------------------------------------------

class _GroupSection extends ConsumerWidget {
  const _GroupSection({required this.group});

  final db.Tile group;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cardsAsync = ref.watch(_groupCardsProvider(group.id));
    final cardCount = cardsAsync.whenOrNull(data: (c) => c.length) ?? 0;

    final countLabel =
        ContentType.fromString(group.contentType) == ContentType.music
            ? '$cardCount Titel'
            : '$cardCount Folgen';

    return SliverToBoxAdapter(
      child: CardSectionHeader(
        title: group.title,
        subtitle: countLabel,
        coverUrl: group.coverUrl,
        icon:
            ContentType.fromString(group.contentType) == ContentType.music
                ? Icons.music_note_rounded
                : Icons.auto_stories_rounded,
        onTap: () => context.push(AppRoutes.parentTileEdit(group.id)),
        onDelete: () => _confirmDeleteGroup(context, ref, group, cardCount),
      ),
    );
  }
}

/// Cards for a group — watches the stream so count stays in sync.
final _groupCardsProvider = StreamProvider.family<List<db.TileItem>, String>((
  ref,
  groupId,
) {
  return ref.watch(tileRepositoryProvider).watchItems(groupId);
});

// ---------------------------------------------------------------------------
// Empty state
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Actions (screen-level helpers)
// ---------------------------------------------------------------------------

void _confirmDeleteGroup(
  BuildContext context,
  WidgetRef ref,
  db.Tile group,
  int cardCount,
) {
  final label = cardCount == 1 ? '1 Karte' : '$cardCount Karten';
  unawaited(
    showDialog<void>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('Kachel löschen?'),
            content: Text(
              '„${group.title}" und $label werden '
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
                  final count = await ref
                      .read(tileItemRepositoryProvider)
                      .deleteByTile(group.id);
                  await ref.read(tileRepositoryProvider).delete(group.id);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context)
                      ..clearSnackBars()
                      ..showSnackBar(
                        SnackBar(
                          content: Text(
                            '${group.title} + $count Karten entfernt',
                          ),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                  }
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

void _confirmDelete(BuildContext context, WidgetRef ref, db.TileItem card) {
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
                  unawaited(
                    ref.read(tileItemRepositoryProvider).delete(card.id),
                  );
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
  db.TileItem card,
) {
  unawaited(
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => GroupPickerSheet(card: card),
    ),
  );
}

// ---------------------------------------------------------------------------
// Retroactive series sorting
// ---------------------------------------------------------------------------

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
    final result = await runRetroactiveSort(
      catalog: catalog,
      cardRepo: ref.read(tileItemRepositoryProvider),
      groupRepo: ref.read(tileRepositoryProvider),
    );

    if (context.mounted) Navigator.of(context).pop();

    if (context.mounted) {
      if (!result.hasMatches) {
        unawaited(
          showDialog<void>(
            context: context,
            builder:
                (_) => AlertDialog(
                  title: const Text('Kacheln sortieren'),
                  content: const Text(
                    'Keine Karten konnten zugeordnet werden.\n'
                    'Tipp: Karten ohne Kachelname im Titel müssen '
                    'manuell einer Kachel zugewiesen werden.',
                  ),
                  actions: [
                    FilledButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('OK'),
                    ),
                  ],
                ),
          ),
        );
      } else {
        unawaited(
          showDialog<void>(
            context: context,
            builder:
                (_) => SortResultDialog(
                  seriesMatches: result.seriesMatches,
                  seriesGroupIds: result.seriesGroupIds,
                  totalMatched: result.totalMatched,
                ),
          ),
        );
      }
    }
  } on Exception catch (e) {
    if (context.mounted) Navigator.of(context).pop();
    Log.error(_tag, 'Retroactive sort failed', exception: e);
  }
}
