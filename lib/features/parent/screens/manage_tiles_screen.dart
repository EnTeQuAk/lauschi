import 'dart:async' show unawaited;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_reorderable_grid_view/widgets/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lauschi/core/database/app_database.dart' as db;
import 'package:lauschi/core/database/tile_item_repository.dart';
import 'package:lauschi/core/database/tile_repository.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/router/app_router.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/parent/widgets/provider_badge.dart';
import 'package:lauschi/features/tiles/screens/tile_detail_screen.dart';
import 'package:lauschi/features/tiles/widgets/tile_card.dart';

const _tag = 'ManageTilesScreen';

/// Parent view: list, create, reorder and delete series groups.
class ManageTilesScreen extends ConsumerWidget {
  const ManageTilesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groupsAsync = ref.watch(allTilesProvider);
    final ungroupedAsync = ref.watch(ungroupedItemsProvider);

    return Scaffold(
      backgroundColor: AppColors.parentBackground,
      appBar: AppBar(
        backgroundColor: AppColors.parentBackground,
        title: const Text('Kacheln verwalten'),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _createGroup(context, ref),
        tooltip: 'Kachel erstellen',
        child: const Icon(Icons.add_rounded),
      ),
      body: groupsAsync.when(
        data: (groups) {
          final ungrouped = ungroupedAsync.whenOrNull(data: (c) => c) ?? [];
          if (groups.isEmpty && ungrouped.isEmpty) {
            return const _EmptyState();
          }
          return _SeriesBody(groups: groups, ungrouped: ungrouped);
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error:
            (_, _) => const Center(
              child: Text('Fehler beim Laden der Kacheln.'),
            ),
      ),
    );
  }

  void _createGroup(BuildContext context, WidgetRef ref) {
    final controller = TextEditingController();
    unawaited(
      showDialog<void>(
        context: context,
        builder:
            (ctx) => AlertDialog(
              title: const Text('Neue Kachel'),
              content: TextField(
                controller: controller,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Name der Kachel',
                  hintText: 'z.B. Yakari, Bibi Blocksberg …',
                ),
                textCapitalization: TextCapitalization.sentences,
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Abbrechen'),
                ),
                FilledButton(
                  onPressed:
                      () => unawaited(
                        _submitCreate(ctx, controller, ref, context),
                      ),
                  child: const Text('Erstellen'),
                ),
              ],
            ),
      ),
    );
  }

  Future<void> _submitCreate(
    BuildContext dialogCtx,
    TextEditingController controller,
    WidgetRef ref,
    BuildContext screenCtx,
  ) async {
    final title = controller.text.trim();
    if (title.isEmpty) return;
    Navigator.of(dialogCtx).pop();
    final groupId = await ref.read(tileRepositoryProvider).insert(title: title);
    Log.info(_tag, 'Tile created', data: {'id': groupId, 'title': title});
    if (screenCtx.mounted) {
      unawaited(screenCtx.push(AppRoutes.parentTileEdit(groupId)));
    }
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.layers_rounded,
            size: 48,
            color: AppColors.textSecondary,
          ),
          SizedBox(height: AppSpacing.md),
          Text(
            'Noch keine Kacheln',
            style: TextStyle(
              fontFamily: 'Nunito',
              fontSize: 16,
              color: AppColors.textSecondary,
            ),
          ),
          SizedBox(height: AppSpacing.sm),
          Text(
            'Tippe auf + um eine Kachel zu erstellen.',
            style: TextStyle(
              fontFamily: 'Nunito',
              fontSize: 14,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

/// Combined view: reorderable series grid + ungrouped cards list.
class _SeriesBody extends StatelessWidget {
  const _SeriesBody({required this.groups, required this.ungrouped});

  final List<db.Tile> groups;
  final List<db.TileItem> ungrouped;

  @override
  Widget build(BuildContext context) {
    if (ungrouped.isEmpty) {
      return _GroupGrid(groups: groups);
    }

    // When there are ungrouped cards, use a column layout so the grid
    // doesn't fight with the list for scroll space.
    return CustomScrollView(
      slivers: [
        if (groups.isNotEmpty)
          SliverToBoxAdapter(
            child: _GroupGrid(groups: groups, shrinkWrap: true),
          ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.screenH,
              AppSpacing.lg,
              AppSpacing.screenH,
              AppSpacing.sm,
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.layers_clear_rounded,
                  size: 20,
                  color: AppColors.textSecondary,
                ),
                const SizedBox(width: AppSpacing.sm),
                Text(
                  'Nicht zugeordnet (${ungrouped.length})',
                  style: const TextStyle(
                    fontFamily: 'Nunito',
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
        SliverList.builder(
          itemCount: ungrouped.length,
          itemBuilder:
              (context, index) => _UngroupedCardTile(card: ungrouped[index]),
        ),
        const SliverPadding(padding: EdgeInsets.only(bottom: AppSpacing.xxl)),
      ],
    );
  }
}

/// Compact tile for an ungrouped card with delete action.
class _UngroupedCardTile extends ConsumerWidget {
  const _UngroupedCardTile({required this.card});

  final db.TileItem card;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.screenH,
      ),
      leading: ClipRRect(
        borderRadius: const BorderRadius.all(Radius.circular(4)),
        child: SizedBox(
          width: 40,
          height: 40,
          child:
              card.coverUrl != null
                  ? CachedNetworkImage(
                    imageUrl: card.coverUrl!,
                    fit: BoxFit.cover,
                  )
                  : const ColoredBox(
                    color: AppColors.surfaceDim,
                    child: Icon(Icons.music_note_rounded, size: 18),
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
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (card.provider != 'spotify')
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: ProviderBadge(provider: card.provider),
            ),
          IconButton(
            onPressed: () => _confirmDeleteCard(context, ref),
            icon: const Icon(Icons.delete_outline_rounded, size: 20),
            color: AppColors.error,
            tooltip: 'Entfernen',
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  void _confirmDeleteCard(BuildContext context, WidgetRef ref) {
    unawaited(
      showDialog<void>(
        context: context,
        builder:
            (ctx) => AlertDialog(
              title: const Text('Eintrag entfernen?'),
              content: Text(
                '„${card.customTitle ?? card.title}" wird '
                'aus der Sammlung entfernt.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Abbrechen'),
                ),
                FilledButton(
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    Log.info(
                      _tag,
                      'Ungrouped card deleted',
                      data: {
                        'cardId': card.id,
                      },
                    );
                    unawaited(
                      ref.read(tileItemRepositoryProvider).delete(card.id),
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
}

/// Reorderable grid of series tiles using flutter_reorderable_grid_view.
///
/// Tiles shift with animation as you drag (iOS home screen style).
/// Long press to start dragging, release to drop.
class _GroupGrid extends ConsumerStatefulWidget {
  const _GroupGrid({required this.groups, this.shrinkWrap = false});

  final List<db.Tile> groups;
  final bool shrinkWrap;

  @override
  ConsumerState<_GroupGrid> createState() => _GroupGridState();
}

class _GroupGridState extends ConsumerState<_GroupGrid> {
  final _scrollController = ScrollController();
  final _gridViewKey = GlobalKey();

  late List<db.Tile> _order;

  @override
  void initState() {
    super.initState();
    _order = List.of(widget.groups);
  }

  @override
  void didUpdateWidget(covariant _GroupGrid old) {
    super.didUpdateWidget(old);
    _order = List.of(widget.groups);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final children = [
      for (final group in _order)
        _GroupTile(key: ValueKey(group.id), group: group),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final columns =
            constraints.maxWidth < 600
                ? 3
                : constraints.maxWidth < 900
                ? 4
                : 5;

        return ReorderableBuilder<db.Tile>(
          scrollController: _scrollController,
          longPressDelay: const Duration(milliseconds: 300),
          onReorder: (reorderFn) {
            setState(() {
              _order = reorderFn(_order);
            });
            Log.info(
              _tag,
              'Tiles reordered',
              data: {
                'count': '${_order.length}',
              },
            );
            unawaited(
              ref
                  .read(tileRepositoryProvider)
                  .reorder(_order.map((g) => g.id).toList()),
            );
          },
          dragChildBoxDecoration: BoxDecoration(
            borderRadius: const BorderRadius.all(AppRadius.card),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withAlpha(40),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          children: children,
          builder: (children) {
            return GridView(
              key: _gridViewKey,
              controller: _scrollController,
              shrinkWrap: widget.shrinkWrap,
              physics:
                  widget.shrinkWrap
                      ? const NeverScrollableScrollPhysics()
                      : null,
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.screenH,
                vertical: AppSpacing.md,
              ),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                crossAxisSpacing: 12,
                mainAxisSpacing: 16,
                childAspectRatio: 0.72,
              ),
              children: children,
            );
          },
        );
      },
    );
  }
}

class _GroupTile extends ConsumerWidget {
  const _GroupTile({required this.group, super.key});

  final db.Tile group;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final episodesAsync = ref.watch(tileItemsProvider(group.id));
    final count = episodesAsync.whenOrNull(data: (e) => e.length) ?? 0;

    return TileCard(
      title: group.title,
      episodeCount: count,
      coverUrl: group.coverUrl,
      contentType: group.contentType,
      onTap: () => context.push(AppRoutes.parentTileEdit(group.id)),
    );
  }
}
