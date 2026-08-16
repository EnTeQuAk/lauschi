import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lauschi/core/catalog/catalog_service.dart' show ContentType;
import 'package:lauschi/core/database/app_database.dart' as db;
import 'package:lauschi/core/database/tile_item_repository.dart';
import 'package:lauschi/core/database/tile_repository.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/router/app_router.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/parent/widgets/draggable_tile_grid.dart';
import 'package:lauschi/features/tiles/screens/tile_detail/screen.dart';

const _tag = 'ManageTilesScreen';

const _tilePrefix = 'tile:';
const _itemPrefix = 'item:';

/// Parent view: list, create, reorder and delete series groups.
///
/// When [parentTileId] is set, shows only child tiles of that parent
/// (scoped manage view for nested tiles). When null, shows root tiles
/// plus any ungrouped items, divided by a horizontal label band.
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
          // Ungrouped items only render at root level. Inside a folder
          // the children are tiles, and any items assigned to the folder
          // itself are managed via tile_edit.
          final ungrouped =
              parentTileId == null
                  ? (ungroupedAsync.whenOrNull(data: (c) => c) ?? [])
                  : <db.TileItem>[];
          if (groups.isEmpty && ungrouped.isEmpty) {
            return const _EmptyState();
          }
          return _MixedGrid(
            tiles: groups,
            items: ungrouped,
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

/// Single draggable grid mixing series tiles and ungrouped items.
///
/// IDs are prefixed (`tile:<uuid>` / `item:<uuid>`) so the drop
/// dispatcher can decode kinds without parallel maps. Reorder splits
/// into the two repos by prefix; nest dispatches into one of five
/// repo calls depending on (dragged, target) kinds.
class _MixedGrid extends ConsumerWidget {
  const _MixedGrid({
    required this.tiles,
    required this.items,
    this.parentTileId,
  });

  final List<db.Tile> tiles;
  final List<db.TileItem> items;
  final String? parentTileId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isNested = parentTileId != null;

    final tileDisplayItems =
        tiles.map((t) {
          final children =
              ref.watch(childTilesProvider(t.id)).value ?? const [];
          final episodeCount =
              ref
                  .watch(tileItemsProvider(t.id))
                  .whenOrNull(data: (e) => e.length) ??
              0;
          return buildTileDisplayItem(
            t,
            children: children,
            episodeCount: episodeCount,
          );
        }).toList();

    final itemDisplayItems = items
        .map(buildItemDisplayItem)
        .toList(growable: false);

    final all = [...tileDisplayItems, ...itemDisplayItems];

    return Column(
      children: [
        const _DragHint(),
        Expanded(
          child: DraggableTileGrid(
            items: all,
            onReorder: (newOrder) => _onReorder(ref, newOrder),
            onNest:
                (draggedId, targetId) =>
                    _onNest(context, ref, draggedId, targetId),
            onTap: (id) => _onTap(context, ref, id),
            dropZones: [
              if (isNested)
                DropZoneConfig(
                  label: 'Auf Startseite',
                  icon: Icons.home_rounded,
                  onDrop: (id) => _onUnnestDrop(context, ref, id),
                ),
              DropZoneConfig(
                label: 'Löschen',
                icon: Icons.delete_rounded,
                color: AppColors.error,
                onDrop: (id) => _onDeleteDrop(ref, id),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ── Dispatch helpers ────────────────────────────────────────────

  /// Decode `tile:` / `item:` prefix → raw uuid.
  static (GridItemKind, String) _decode(String id) {
    if (id.startsWith(_tilePrefix)) {
      return (GridItemKind.tile, id.substring(_tilePrefix.length));
    }
    if (id.startsWith(_itemPrefix)) {
      return (GridItemKind.episode, id.substring(_itemPrefix.length));
    }
    throw ArgumentError('Unprefixed grid id: $id');
  }

  void _onReorder(WidgetRef ref, List<String> newOrder) {
    final tileIds = <String>[];
    final itemIds = <String>[];
    for (final encoded in newOrder) {
      final (kind, raw) = _decode(encoded);
      if (kind == GridItemKind.tile) {
        tileIds.add(raw);
      } else {
        itemIds.add(raw);
      }
    }
    Log.info(
      _tag,
      'Mixed reorder',
      data: {'tiles': '${tileIds.length}', 'items': '${itemIds.length}'},
    );
    final tileRepo = ref.read(tileRepositoryProvider);
    final itemRepo = ref.read(tileItemRepositoryProvider);
    if (tileIds.isNotEmpty) unawaited(tileRepo.reorder(tileIds));
    if (itemIds.isNotEmpty) unawaited(itemRepo.reorder(itemIds));
  }

  void _onNest(
    BuildContext context,
    WidgetRef ref,
    String draggedEncoded,
    String targetEncoded,
  ) {
    final (draggedKind, draggedId) = _decode(draggedEncoded);
    final (targetKind, targetId) = _decode(targetEncoded);
    final tileRepo = ref.read(tileRepositoryProvider);
    final itemRepo = ref.read(tileItemRepositoryProvider);

    Log.info(
      _tag,
      'Nest dispatch',
      data: {
        'dragged': '${draggedKind.name}:$draggedId',
        'target': '${targetKind.name}:$targetId',
      },
    );

    if (draggedKind == GridItemKind.tile && targetKind == GridItemKind.tile) {
      // Reuse the existing folder-create / nest-into logic.
      final targetChildren =
          ref.read(childTilesProvider(targetId)).value ?? const [];
      final targetIsFolder = targetChildren.isNotEmpty;
      if (targetIsFolder) {
        unawaited(tileRepo.nestInto(childId: draggedId, parentId: targetId));
      } else {
        unawaited(
          tileRepo.createFolderFromDrag(
            draggedId: draggedId,
            targetId: targetId,
          ),
        );
      }
      return;
    }

    if (draggedKind == GridItemKind.episode &&
        targetKind == GridItemKind.tile) {
      // Drop an episode onto a tile/folder → assign it there.
      unawaited(itemRepo.assignToTile(itemId: draggedId, tileId: targetId));
      return;
    }

    if (draggedKind == GridItemKind.tile &&
        targetKind == GridItemKind.episode) {
      unawaited(
        tileRepo.createTileFromTileAndItem(
          tileId: draggedId,
          itemId: targetId,
        ),
      );
      return;
    }

    if (draggedKind == GridItemKind.episode &&
        targetKind == GridItemKind.episode) {
      unawaited(
        _createTileAndJump(context, ref, [draggedId, targetId]),
      );
      return;
    }
  }

  Future<void> _createTileAndJump(
    BuildContext context,
    WidgetRef ref,
    List<String> itemIds,
  ) async {
    final newTileId = await ref
        .read(tileRepositoryProvider)
        .createTileFromItems(itemIds);
    if (!context.mounted) return;
    // Surface the rename affordance immediately — the default
    // "Neue Kachel" is rarely what the parent wants.
    unawaited(context.push(AppRoutes.parentTileEdit(newTileId)));
  }

  void _onTap(BuildContext context, WidgetRef ref, String encoded) {
    final (kind, raw) = _decode(encoded);
    if (kind == GridItemKind.episode) {
      unawaited(context.push(AppRoutes.parentTileItemEdit(raw)));
      return;
    }
    // Tile: drill into children, or open the edit screen if it's a leaf.
    final hasKids =
        ref
            .read(childTilesProvider(raw))
            .whenOrNull(data: (c) => c.isNotEmpty) ??
        false;
    if (hasKids) {
      unawaited(context.push(AppRoutes.parentTileChildren(raw)));
    } else {
      unawaited(context.push(AppRoutes.parentTileEdit(raw)));
    }
  }

  void _onUnnestDrop(BuildContext context, WidgetRef ref, String encoded) {
    final (kind, raw) = _decode(encoded);
    if (kind != GridItemKind.tile) return; // episodes can't be unnested here
    Log.info(_tag, 'Unnest via drop zone', data: {'tileId': raw});
    unawaited(ref.read(tileRepositoryProvider).unnest(raw));
    final remaining = tiles.where((t) => t.id != raw).length;
    if (remaining == 0 && context.mounted) context.pop();
  }

  void _onDeleteDrop(WidgetRef ref, String encoded) {
    final (kind, raw) = _decode(encoded);
    Log.info(
      _tag,
      'Delete via drop zone',
      data: {'kind': kind.name, 'id': raw},
    );
    if (kind == GridItemKind.tile) {
      unawaited(ref.read(tileRepositoryProvider).delete(raw));
    } else {
      unawaited(ref.read(tileItemRepositoryProvider).delete(raw));
    }
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
          Expanded(
            child: Text(
              'Halten & ziehen um zu sortieren oder zu gruppieren',
              style: TextStyle(
                fontFamily: 'Nunito',
                fontSize: 12,
                color: AppColors.textSecondary.withAlpha(150),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Build display model from a tile and its children/episodes.
/// Pure transformation, no provider access.
DraggableTileItem buildTileDisplayItem(
  db.Tile tile, {
  required List<db.Tile> children,
  required int episodeCount,
}) {
  final childCovers =
      children
          .where((t) => t.coverUrl != null)
          .take(4)
          .map((t) => t.coverUrl!)
          .toList();

  final title = children.isNotEmpty ? folderName(children) : tile.title;

  return DraggableTileItem(
    id: '$_tilePrefix${tile.id}',
    title: title,
    coverUrl: tile.coverUrl,
    episodeCount: episodeCount,
    contentType: ContentType.fromString(tile.contentType),
    childCount: children.length,
    childCoverUrls: childCovers,
  );
}

/// Build display model from an ungrouped item. The cell looks like a
/// tile so the parent sees a homogeneous grid; the divider band above
/// tells them this row is single episodes.
DraggableTileItem buildItemDisplayItem(db.TileItem item) {
  return DraggableTileItem(
    id: '$_itemPrefix${item.id}',
    title: item.customTitle ?? item.title,
    coverUrl: item.coverUrl,
    episodeCount: 1,
    kind: GridItemKind.episode,
  );
}

/// Human label for a folder from its children: the single name for one,
/// "A & B" for two, "A, B & mehr" for three or more, "Leerer Ordner" when
/// empty.
String folderName(List<db.Tile> children) {
  if (children.isEmpty) return 'Leerer Ordner';
  final names = children.map((t) => t.title).toList();
  if (names.length == 1) return names.first;
  if (names.length == 2) return '${names[0]} & ${names[1]}';
  return '${names[0]}, ${names[1]} & mehr';
}
