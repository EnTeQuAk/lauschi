import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
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

class _GroupGrid extends ConsumerStatefulWidget {
  const _GroupGrid({required this.groups});

  final List<db.CardGroup> groups;

  @override
  ConsumerState<_GroupGrid> createState() => _GroupGridState();
}

class _GroupGridState extends ConsumerState<_GroupGrid> {
  int? _dragFromIndex;
  int? _hoverIndex;

  void _reorder(int from, int to) {
    if (from == to) return;
    final reordered = List<db.CardGroup>.from(widget.groups);
    final item = reordered.removeAt(from);
    reordered.insert(to, item);
    unawaited(
      ref
          .read(groupRepositoryProvider)
          .reorder(reordered.map((g) => g.id).toList()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns =
            constraints.maxWidth < 600
                ? 3
                : constraints.maxWidth < 900
                ? 4
                : 5;

        return GridView.builder(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.screenH,
            vertical: AppSpacing.md,
          ),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: 12,
            mainAxisSpacing: 16,
            // Same as parent browse catalog: 1:1 image + text below
            childAspectRatio: 0.72,
          ),
          itemCount: widget.groups.length,
          itemBuilder: (context, index) {
            final group = widget.groups[index];
            return _DraggableGroupTile(
              key: ValueKey(group.id),
              group: group,
              index: index,
              isDragSource: _dragFromIndex == index,
              isHoverTarget: _hoverIndex == index,
              onDragStarted: () => setState(() => _dragFromIndex = index),
              onDragEnd: () => setState(() {
                _dragFromIndex = null;
                _hoverIndex = null;
              }),
              onHover: () {
                if (_hoverIndex != index) setState(() => _hoverIndex = index);
              },
              onHoverExit: () {
                if (_hoverIndex == index) setState(() => _hoverIndex = null);
              },
              onAccept: (fromIndex) {
                _reorder(fromIndex, index);
                setState(() {
                  _dragFromIndex = null;
                  _hoverIndex = null;
                });
              },
              onTap: () => context.push(AppRoutes.parentGroupEdit(group.id)),
            );
          },
        );
      },
    );
  }
}

class _DraggableGroupTile extends ConsumerWidget {
  const _DraggableGroupTile({
    required this.group,
    required this.index,
    required this.isDragSource,
    required this.isHoverTarget,
    required this.onDragStarted,
    required this.onDragEnd,
    required this.onHover,
    required this.onHoverExit,
    required this.onAccept,
    required this.onTap,
    super.key,
  });

  final db.CardGroup group;
  final int index;
  final bool isDragSource;
  final bool isHoverTarget;
  final VoidCallback onDragStarted;
  final VoidCallback onDragEnd;
  final VoidCallback onHover;
  final VoidCallback onHoverExit;
  final void Function(int fromIndex) onAccept;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final episodesAsync = ref.watch(groupEpisodesProvider(group.id));
    final count = episodesAsync.whenOrNull(data: (e) => e.length) ?? 0;

    final tile = GroupCard(
      title: group.title,
      episodeCount: count,
      coverUrl: group.coverUrl,
      contentType: group.contentType,
      onTap: onTap,
    );

    return DragTarget<int>(
      onWillAcceptWithDetails: (details) {
        onHover();
        return details.data != index;
      },
      onLeave: (_) => onHoverExit(),
      onAcceptWithDetails: (details) => onAccept(details.data),
      builder: (context, accepted, rejected) {
        return LongPressDraggable<int>(
          data: index,
          onDragStarted: onDragStarted,
          onDragEnd: (_) => onDragEnd(),
          onDraggableCanceled: (_, _) => onDragEnd(),
          feedback: Material(
            elevation: 8,
            color: Colors.transparent,
            borderRadius: const BorderRadius.all(AppRadius.card),
            child: SizedBox(
              width: 120,
              height: 150,
              child: tile,
            ),
          ),
          childWhenDragging: Opacity(opacity: 0.3, child: tile),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            decoration: BoxDecoration(
              borderRadius: const BorderRadius.all(AppRadius.card),
              border:
                  isHoverTarget
                      ? Border.all(color: AppColors.primary, width: 2)
                      : null,
            ),
            child: tile,
          ),
        );
      },
    );
  }
}
