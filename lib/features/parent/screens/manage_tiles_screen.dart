import 'dart:async' show unawaited;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lauschi/core/catalog/catalog_service.dart' show ContentType;
import 'package:lauschi/core/database/app_database.dart' as db;
import 'package:lauschi/core/database/tile_item_repository.dart';
import 'package:lauschi/core/database/tile_repository.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/providers/provider_type.dart';
import 'package:lauschi/core/router/app_router.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/parent/widgets/draggable_tile_grid.dart';
import 'package:lauschi/features/parent/widgets/provider_badge.dart';
import 'package:lauschi/features/tiles/screens/tile_detail_screen.dart';

const _tag = 'ManageTilesScreen';

/// Parent view: list, create, reorder and delete series groups.
///
/// When [parentTileId] is set, shows only child tiles of that parent
/// (scoped manage view for nested tiles). When null, shows root tiles.
class ManageTilesScreen extends ConsumerWidget {
  const ManageTilesScreen({super.key, this.parentTileId});

  final String? parentTileId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groupsAsync =
        parentTileId != null
            ? ref.watch(childTilesProvider(parentTileId!))
            : ref.watch(allTilesProvider);
    final ungroupedAsync = ref.watch(ungroupedItemsProvider);

    return Scaffold(
      backgroundColor: AppColors.parentBackground,
      appBar: AppBar(
        backgroundColor: AppColors.parentBackground,
        title: Text(
          parentTileId != null ? 'Ordner verwalten' : 'Kacheln verwalten',
        ),
      ),
      floatingActionButton: FloatingActionButton(
        key: const Key('add_content_fab'),
        onPressed: () => context.push(AppRoutes.parentAddContent),
        tooltip: 'Hörspiel hinzufügen',
        child: const Icon(Icons.add_rounded),
      ),
      body: groupsAsync.when(
        data: (groups) {
          // Ungrouped items only shown at root level, not inside a parent.
          final ungrouped =
              parentTileId == null
                  ? (ungroupedAsync.whenOrNull(data: (c) => c) ?? [])
                  : <db.TileItem>[];
          if (groups.isEmpty && ungrouped.isEmpty) {
            return const _EmptyState();
          }
          return _SeriesBody(
            groups: groups,
            ungrouped: ungrouped,
            parentTileId: parentTileId,
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error:
            (_, _) => const Center(
              child: Text('Fehler beim Laden der Kacheln.'),
            ),
      ),
    );
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
            'Tippe auf + um ein Hörspiel hinzuzufügen.',
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
  const _SeriesBody({
    required this.groups,
    required this.ungrouped,
    this.parentTileId,
  });

  final List<db.Tile> groups;
  final List<db.TileItem> ungrouped;
  final String? parentTileId;

  @override
  Widget build(BuildContext context) {
    final isNested = parentTileId != null;
    if (ungrouped.isEmpty) {
      return Column(
        children: [
          const _DragHint(),
          Expanded(child: _GroupGrid(groups: groups, isNested: isNested)),
        ],
      );
    }

    // When there are ungrouped cards, use a column layout so the grid
    // doesn't fight with the list for scroll space.
    return CustomScrollView(
      slivers: [
        if (groups.isNotEmpty)
          SliverToBoxAdapter(
            child: _GroupGrid(
              groups: groups,
              shrinkWrap: true,
              isNested: isNested,
            ),
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
          if (card.provider != ProviderType.spotify.value)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: ProviderBadge(
                provider: ProviderType.fromString(card.provider),
              ),
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
class _GroupGrid extends ConsumerWidget {
  const _GroupGrid({
    required this.groups,
    this.shrinkWrap = false,
    this.isNested = false,
  });

  final List<db.Tile> groups;
  final bool shrinkWrap;
  final bool isNested;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items =
        groups.map((g) {
          final childTiles = ref.watch(childTilesProvider(g.id));
          final episodes = ref.watch(tileItemsProvider(g.id));
          final numChildren = childTiles.whenOrNull(data: (c) => c.length) ?? 0;
          final numEpisodes = episodes.whenOrNull(data: (e) => e.length) ?? 0;

          final childCovers =
              childTiles.whenOrNull(
                data:
                    (tiles) =>
                        tiles
                            .where((t) => t.coverUrl != null)
                            .take(4)
                            .map((t) => t.coverUrl!)
                            .toList(),
              ) ??
              const <String>[];

          // Folders: derive display name from children.
          final title =
              numChildren > 0 ? _folderName(childTiles.value ?? []) : g.title;

          return DraggableTileItem(
            id: g.id,
            title: title,
            coverUrl: g.coverUrl,
            episodeCount: numEpisodes,
            contentType: ContentType.fromString(g.contentType),
            childCount: numChildren,
            childCoverUrls: childCovers,
          );
        }).toList();

    return DraggableTileGrid(
      items: items,
      onReorder: (newOrder) {
        Log.info(
          _tag,
          'Tiles reordered',
          data: {'count': '${newOrder.length}'},
        );
        unawaited(ref.read(tileRepositoryProvider).reorder(newOrder));
      },
      onNest: (draggedId, targetId) {
        final targetChildren =
            ref.read(childTilesProvider(targetId)).value ?? [];
        final isFolder = targetChildren.isNotEmpty;
        final repo = ref.read(tileRepositoryProvider);

        if (isFolder) {
          // Target is already a folder: nest into it.
          Log.info(
            _tag,
            'Nesting into existing folder',
            data: {
              'dragged': draggedId,
              'folder': targetId,
            },
          );
          unawaited(repo.nestInto(childId: draggedId, parentId: targetId));
        } else {
          // Both are leaf tiles: create a new folder containing both.
          Log.info(
            _tag,
            'Creating folder via drag',
            data: {
              'dragged': draggedId,
              'target': targetId,
            },
          );
          unawaited(
            repo.createFolderFromDrag(
              draggedId: draggedId,
              targetId: targetId,
            ),
          );
        }
      },
      onTap: (id) {
        final hasKids =
            ref
                .read(childTilesProvider(id))
                .whenOrNull(
                  data: (c) => c.isNotEmpty,
                ) ??
            false;
        if (hasKids) {
          unawaited(context.push(AppRoutes.parentTileChildren(id)));
        } else {
          unawaited(context.push(AppRoutes.parentTileEdit(id)));
        }
      },
      onLongPress: (id) {
        final group = groups.firstWhere((g) => g.id == id);
        _showContextMenu(context, ref, group, isNested);
      },
      dropZones: [
        if (isNested)
          DropZoneConfig(
            label: 'Auf Startseite',
            icon: Icons.home_rounded,
            onDrop: (id) {
              Log.info(_tag, 'Unnest via drop zone', data: {'tileId': id});
              unawaited(ref.read(tileRepositoryProvider).unnest(id));
              final remaining = items.where((t) => t.id != id).length;
              if (remaining == 0 && context.mounted) {
                context.pop();
              }
            },
          ),
        DropZoneConfig(
          label: 'Löschen',
          icon: Icons.delete_rounded,
          color: AppColors.error,
          onDrop: (id) {
            Log.info(_tag, 'Delete via drop zone', data: {'tileId': id});
            unawaited(ref.read(tileRepositoryProvider).delete(id));
          },
        ),
      ],
    );
  }
}

class _DragHint extends StatelessWidget {
  const _DragHint();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.screenH,
        AppSpacing.xs,
        AppSpacing.screenH,
        0,
      ),
      child: Row(
        children: [
          Icon(
            Icons.touch_app_rounded,
            size: 14,
            color: AppColors.textSecondary.withAlpha(150),
          ),
          const SizedBox(width: 6),
          Text(
            'Gedrückt halten zum Verschieben, auf eine Kachel ziehen zum Gruppieren',
            style: TextStyle(
              fontFamily: 'Nunito',
              fontSize: 12,
              color: AppColors.textSecondary.withAlpha(150),
            ),
          ),
        ],
      ),
    );
  }
}

/// Derive a folder display name from its children.
/// "A & B" for 2, "A, B & 1 weiterer" for 3, etc.
String _folderName(List<db.Tile> children) {
  if (children.isEmpty) return 'Leerer Ordner';
  final names = children.map((t) => t.title).toList();
  if (names.length == 1) return names.first;
  if (names.length == 2) return '${names[0]} & ${names[1]}';
  return '${names[0]}, ${names[1]} & mehr';
}

/// Show context menu for a tile (long-press fallback for accessibility).
void _showContextMenu(
  BuildContext context,
  WidgetRef ref,
  db.Tile group,
  bool isNested,
) {
  final tileRepo = ref.read(tileRepositoryProvider);

  unawaited(
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!isNested)
                ListTile(
                  leading: const Icon(Icons.folder_rounded),
                  title: const Text('Verschieben in...'),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    unawaited(_showMoveIntoDialog(context, ref, group));
                  },
                ),
              if (isNested)
                ListTile(
                  leading: const Icon(Icons.move_up_rounded),
                  title: const Text('Auf Startseite verschieben'),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    unawaited(tileRepo.unnest(group.id));
                    Log.info(
                      _tag,
                      'Tile unnested',
                      data: {'tileId': group.id, 'title': group.title},
                    );
                  },
                ),
              ListTile(
                leading: const Icon(Icons.edit_rounded),
                title: const Text('Bearbeiten'),
                onTap: () {
                  Navigator.of(ctx).pop();
                  unawaited(context.push(AppRoutes.parentTileEdit(group.id)));
                },
              ),
              ListTile(
                leading: const Icon(
                  Icons.delete_outline_rounded,
                  color: AppColors.error,
                ),
                title: const Text(
                  'Löschen',
                  style: TextStyle(color: AppColors.error),
                ),
                onTap: () {
                  Navigator.of(ctx).pop();
                  unawaited(_confirmDelete(context, ref, group));
                },
              ),
            ],
          ),
        );
      },
    ),
  );
}

Future<void> _showMoveIntoDialog(
  BuildContext context,
  WidgetRef ref,
  db.Tile group,
) async {
  final tileRepo = ref.read(tileRepositoryProvider);

  await showDialog<void>(
    context: context,
    builder: (ctx) {
      return Consumer(
        builder: (context, ref, _) {
          final tilesAsync = ref.watch(allTilesProvider);
          return AlertDialog(
            title: const Text('Verschieben in...'),
            content: tilesAsync.when(
              data: (tiles) {
                final candidates =
                    tiles.where((t) => t.id != group.id).toList();
                if (candidates.isEmpty) {
                  return const Text('Keine Kacheln verfügbar.');
                }
                return SizedBox(
                  width: double.maxFinite,
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: candidates.length,
                    itemBuilder: (context, index) {
                      final target = candidates[index];
                      return ListTile(
                        leading: ClipRRect(
                          borderRadius: const BorderRadius.all(
                            Radius.circular(4),
                          ),
                          child: SizedBox(
                            width: 40,
                            height: 40,
                            child:
                                target.coverUrl != null
                                    ? CachedNetworkImage(
                                      imageUrl: target.coverUrl!,
                                      fit: BoxFit.cover,
                                    )
                                    : const ColoredBox(
                                      color: AppColors.surfaceDim,
                                      child: Icon(
                                        Icons.folder_rounded,
                                        size: 18,
                                      ),
                                    ),
                          ),
                        ),
                        title: Text(target.title),
                        onTap: () {
                          Navigator.of(ctx).pop();
                          unawaited(
                            tileRepo.nestInto(
                              childId: group.id,
                              parentId: target.id,
                            ),
                          );
                          Log.info(
                            _tag,
                            'Tile moved into parent',
                            data: {
                              'childId': group.id,
                              'parentId': target.id,
                              'parentTitle': target.title,
                            },
                          );
                        },
                      );
                    },
                  ),
                );
              },
              loading: () => const CircularProgressIndicator(),
              error: (_, _) => const Text('Fehler beim Laden.'),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Abbrechen'),
              ),
            ],
          );
        },
      );
    },
  );
}

Future<void> _confirmDelete(
  BuildContext context,
  WidgetRef ref,
  db.Tile group,
) async {
  await showDialog<void>(
    context: context,
    builder:
        (ctx) => AlertDialog(
          title: const Text('Kachel löschen?'),
          content: Text(
            '\u201e${group.title}\u201c und alle enthaltenen Inhalte '
            'werden gelöscht.',
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
                  'Tile deleted',
                  data: {'tileId': group.id, 'title': group.title},
                );
                unawaited(
                  ref.read(tileRepositoryProvider).delete(group.id),
                );
              },
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.error,
              ),
              child: const Text('Löschen'),
            ),
          ],
        ),
  );
}
