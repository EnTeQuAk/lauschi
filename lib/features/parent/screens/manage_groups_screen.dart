import 'dart:async' show unawaited;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_reorderable_grid_view/widgets/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lauschi/core/database/app_database.dart' as db;
import 'package:lauschi/core/database/card_repository.dart';
import 'package:lauschi/core/database/group_repository.dart';
import 'package:lauschi/core/router/app_router.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/cards/screens/group_detail_screen.dart';
import 'package:lauschi/features/cards/widgets/group_card.dart';
import 'package:lauschi/features/parent/widgets/provider_badge.dart';

/// Parent view: list, create, reorder and delete series groups.
class ManageGroupsScreen extends ConsumerWidget {
  const ManageGroupsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groupsAsync = ref.watch(allGroupsProvider);
    final ungroupedAsync = ref.watch(ungroupedCardsProvider);

    return Scaffold(
      backgroundColor: AppColors.parentBackground,
      appBar: AppBar(
        backgroundColor: AppColors.parentBackground,
        title: const Text('Serien verwalten'),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _createGroup(context, ref),
        tooltip: 'Serie erstellen',
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
              child: Text('Fehler beim Laden der Serien.'),
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
              title: const Text('Neue Serie'),
              content: TextField(
                controller: controller,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Serientitel',
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
    final groupId = await ref
        .read(groupRepositoryProvider)
        .insert(title: title);
    if (screenCtx.mounted) {
      unawaited(screenCtx.push(AppRoutes.parentGroupEdit(groupId)));
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
            'Noch keine Serien',
            style: TextStyle(
              fontFamily: 'Nunito',
              fontSize: 16,
              color: AppColors.textSecondary,
            ),
          ),
          SizedBox(height: AppSpacing.sm),
          Text(
            'Tippe auf + um eine Serie zu erstellen.',
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

  final List<db.CardGroup> groups;
  final List<db.AudioCard> ungrouped;

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
                  'Ohne Serie (${ungrouped.length})',
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

  final db.AudioCard card;

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
              title: const Text('Karte entfernen?'),
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
                    unawaited(ref.read(cardRepositoryProvider).delete(card.id));
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

  final List<db.CardGroup> groups;
  final bool shrinkWrap;

  @override
  ConsumerState<_GroupGrid> createState() => _GroupGridState();
}

class _GroupGridState extends ConsumerState<_GroupGrid> {
  final _scrollController = ScrollController();
  final _gridViewKey = GlobalKey();

  late List<db.CardGroup> _order;

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

        return ReorderableBuilder<db.CardGroup>(
          scrollController: _scrollController,
          longPressDelay: const Duration(milliseconds: 300),
          onReorder: (reorderFn) {
            setState(() {
              _order = reorderFn(_order);
            });
            unawaited(
              ref
                  .read(groupRepositoryProvider)
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

  final db.CardGroup group;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final episodesAsync = ref.watch(groupEpisodesProvider(group.id));
    final count = episodesAsync.whenOrNull(data: (e) => e.length) ?? 0;

    return GroupCard(
      title: group.title,
      episodeCount: count,
      coverUrl: group.coverUrl,
      contentType: group.contentType,
      onTap: () => context.push(AppRoutes.parentGroupEdit(group.id)),
    );
  }
}
