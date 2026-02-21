import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_reorderable_grid_view/widgets/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lauschi/core/database/app_database.dart' as db;
import 'package:lauschi/core/database/group_repository.dart';
import 'package:lauschi/core/router/app_router.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/cards/screens/group_detail_screen.dart';
import 'package:lauschi/features/cards/widgets/group_card.dart';

/// Parent view: list, create, reorder and delete series groups.
class ManageGroupsScreen extends ConsumerWidget {
  const ManageGroupsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groupsAsync = ref.watch(allGroupsProvider);

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
        data:
            (groups) =>
                groups.isEmpty
                    ? const _EmptyState()
                    : _GroupGrid(groups: groups),
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

/// Reorderable grid of series tiles using flutter_reorderable_grid_view.
///
/// Tiles shift with animation as you drag (iOS home screen style).
/// Long press to start dragging, release to drop.
class _GroupGrid extends ConsumerStatefulWidget {
  const _GroupGrid({required this.groups});

  final List<db.CardGroup> groups;

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
