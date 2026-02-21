import 'dart:async' show unawaited;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lauschi/core/database/app_database.dart' as db;
import 'package:lauschi/core/database/card_repository.dart';
import 'package:lauschi/core/database/group_repository.dart';
import 'package:lauschi/core/router/app_router.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/cards/screens/group_detail_screen.dart';

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
                    : _GroupList(groups: groups),
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

class _GroupList extends ConsumerWidget {
  const _GroupList({required this.groups});

  final List<db.CardGroup> groups;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ReorderableListView.builder(
      padding: const EdgeInsets.only(bottom: AppSpacing.xxl),
      buildDefaultDragHandles: false,
      onReorder: (oldIndex, newIndex) {
        final insertAt = newIndex > oldIndex ? newIndex - 1 : newIndex;
        final reordered = List<db.CardGroup>.from(groups);
        final item = reordered.removeAt(oldIndex);
        reordered.insert(insertAt, item);
        unawaited(
          ref
              .read(groupRepositoryProvider)
              .reorder(
                reordered.map((g) => g.id).toList(),
              ),
        );
      },
      itemCount: groups.length,
      itemBuilder: (context, index) {
        final group = groups[index];
        return _GroupTile(
          key: ValueKey(group.id),
          group: group,
          index: index,
          onTap: () => context.push(AppRoutes.parentGroupEdit(group.id)),
          onDelete: () => _confirmDelete(context, ref, group),
        );
      },
    );
  }

  void _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    db.CardGroup group,
  ) {
    unawaited(
      showDialog<void>(
        context: context,
        builder:
            (ctx) => AlertDialog(
              title: const Text('Serie entfernen?'),
              content: Text('„${group.title}" löschen?'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Abbrechen'),
                ),
                OutlinedButton(
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    unawaited(
                      ref.read(groupRepositoryProvider).delete(group.id),
                    );
                  },
                  child: const Text('Nur Serie'),
                ),
                FilledButton(
                  onPressed: () async {
                    Navigator.of(ctx).pop();
                    await ref
                        .read(cardRepositoryProvider)
                        .deleteByGroup(group.id);
                    await ref.read(groupRepositoryProvider).delete(group.id);
                  },
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.error,
                  ),
                  child: const Text('Serie + Karten'),
                ),
              ],
            ),
      ),
    );
  }
}

class _GroupTile extends ConsumerWidget {
  const _GroupTile({
    required this.group,
    required this.index,
    required this.onTap,
    required this.onDelete,
    super.key,
  });

  final db.CardGroup group;
  final int index;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final episodesAsync = ref.watch(groupEpisodesProvider(group.id));
    final count = episodesAsync.whenOrNull(data: (e) => e.length) ?? 0;

    return ListTile(
      tileColor: AppColors.parentSurface,
      onTap: onTap,
      leading: ClipRRect(
        borderRadius: const BorderRadius.all(Radius.circular(8)),
        child: SizedBox(
          width: 44,
          height: 44,
          child:
              group.coverUrl != null
                  ? CachedNetworkImage(
                    imageUrl: group.coverUrl!,
                    fit: BoxFit.cover,
                  )
                  : const ColoredBox(
                    color: AppColors.surfaceDim,
                    child: Icon(
                      Icons.layers_rounded,
                      color: AppColors.primary,
                      size: 22,
                    ),
                  ),
        ),
      ),
      title: Text(
        group.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          fontFamily: 'Nunito',
          fontWeight: FontWeight.w600,
          fontSize: 15,
        ),
      ),
      subtitle: Text(
        count == 1 ? '1 Folge' : '$count Folgen',
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
            onPressed: onDelete,
            icon: const Icon(Icons.delete_outline_rounded),
            color: AppColors.error,
            tooltip: 'Löschen',
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
