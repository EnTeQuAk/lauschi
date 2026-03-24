import 'dart:async' show Timer, unawaited;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_reorderable_grid_view/widgets/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lauschi/core/database/app_database.dart' as db;
import 'package:lauschi/core/database/tile_item_repository.dart';
import 'package:lauschi/core/database/tile_repository.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/providers/provider_type.dart';
import 'package:lauschi/core/router/app_router.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/parent/widgets/provider_badge.dart';
import 'package:lauschi/features/tiles/screens/tile_detail_screen.dart';
import 'package:lauschi/features/tiles/widgets/tile_card.dart';

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
      return _GroupGrid(groups: groups, isNested: isNested);
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
class _GroupGrid extends ConsumerStatefulWidget {
  const _GroupGrid({
    required this.groups,
    this.shrinkWrap = false,
    this.isNested = false,
  });

  final List<db.Tile> groups;
  final bool shrinkWrap;
  final bool isNested;

  @override
  ConsumerState<_GroupGrid> createState() => _GroupGridState();
}

class _GroupGridState extends ConsumerState<_GroupGrid> {
  final _scrollController = ScrollController();
  final _gridViewKey = GlobalKey();

  late List<db.Tile> _order;

  // ── Nest-on-hover state ──────────────────────────────────────────
  /// Index of the tile being dragged (null when not dragging).
  int? _draggedIndex;

  /// ID of the tile currently under the pointer as a nest target.
  String? _nestTargetId;

  /// Timer for the 500ms hover threshold before activating nest mode.
  Timer? _hoverTimer;

  /// Set to true when the hover timer fires and the nest target is active.
  /// When true, the next drop will nest instead of reorder.
  bool _nestModeActive = false;

  /// Columns in the current layout (needed for hit-testing).
  int _columns = 3;

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
    _hoverTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  // ── Pointer tracking during drag ─────────────────────────────────

  void _onPointerMove(PointerMoveEvent event) {
    if (_draggedIndex == null) return;

    // Find which tile the pointer is over using grid geometry.
    final gridBox =
        _gridViewKey.currentContext?.findRenderObject() as RenderBox?;
    if (gridBox == null) return;

    final local = gridBox.globalToLocal(event.position);
    final targetIndex = _hitTestGrid(local);

    // Determine the target tile ID (ignoring the dragged tile itself).
    String? targetId;
    if (targetIndex != null &&
        targetIndex != _draggedIndex &&
        targetIndex >= 0 &&
        targetIndex < _order.length) {
      targetId = _order[targetIndex].id;
    }

    if (targetId != _nestTargetId) {
      // Pointer moved to a different tile (or off all tiles).
      _cancelHover();
      if (targetId != null) {
        _startHover(targetId);
      }
    }
  }

  /// Map a local offset within the grid to a tile index.
  /// Returns null if the pointer is outside the grid or in padding/gaps.
  int? _hitTestGrid(Offset local) {
    const padding = AppSpacing.screenH; // horizontal padding
    const vPadding = AppSpacing.md; // vertical padding
    const crossSpacing = 12.0;
    const mainSpacing = 16.0;
    const aspectRatio = 0.72;

    final gridWidth =
        (_gridViewKey.currentContext?.size?.width ?? 0) - padding * 2;
    if (gridWidth <= 0) return null;

    final cellWidth = (gridWidth - crossSpacing * (_columns - 1)) / _columns;
    final cellHeight = cellWidth / aspectRatio;

    // Account for padding offset.
    final x = local.dx - padding;
    final y = local.dy - vPadding + _scrollController.offset;

    if (x < 0 || y < 0) return null;

    final col = (x / (cellWidth + crossSpacing)).floor();
    final row = (y / (cellHeight + mainSpacing)).floor();

    if (col < 0 || col >= _columns) return null;

    // Check if the pointer is actually inside the cell (not in the gap).
    final cellX = x - col * (cellWidth + crossSpacing);
    final cellY = y - row * (cellHeight + mainSpacing);
    if (cellX > cellWidth || cellY > cellHeight) return null;

    final index = row * _columns + col;
    return index < _order.length ? index : null;
  }

  void _startHover(String targetId) {
    _nestTargetId = targetId;
    _hoverTimer = Timer(const Duration(milliseconds: 500), () {
      if (_nestTargetId == targetId && _draggedIndex != null) {
        setState(() => _nestModeActive = true);
        unawaited(HapticFeedback.mediumImpact());
        Log.debug(
          _tag,
          'Nest mode activated',
          data: {'targetId': targetId},
        );
      }
    });
    // Subtle initial feedback: show the target is being considered.
    setState(() {});
  }

  void _cancelHover() {
    _hoverTimer?.cancel();
    _hoverTimer = null;
    if (_nestTargetId != null || _nestModeActive) {
      setState(() {
        _nestTargetId = null;
        _nestModeActive = false;
      });
    }
  }

  // ignore: use_setters_to_change_properties, callback from ReorderableBuilder
  void _onDragStarted(int index) => _draggedIndex = index;

  void _onDragEnd(int index) {
    _draggedIndex = null;
    _cancelHover();
  }

  // ── Build ────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final children = [
      for (var i = 0; i < _order.length; i++)
        _GroupTile(
          key: ValueKey(_order[i].id),
          group: _order[i],
          isNested: widget.isNested,
          isNestTarget: _nestModeActive && _order[i].id == _nestTargetId,
          isNestCandidate:
              !_nestModeActive &&
              _nestTargetId == _order[i].id &&
              _draggedIndex != null,
        ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        _columns =
            constraints.maxWidth < 600
                ? 3
                : constraints.maxWidth < 900
                ? 4
                : 5;

        return Listener(
          onPointerMove: _onPointerMove,
          child: ReorderableBuilder<db.Tile>(
            scrollController: _scrollController,
            longPressDelay: const Duration(milliseconds: 300),
            onDragStarted: _onDragStarted,
            onDragEnd: _onDragEnd,
            onReorder: (reorderFn) {
              // If nest mode is active, intercept the drop.
              if (_nestModeActive && _nestTargetId != null) {
                final draggedId =
                    _draggedIndex != null && _draggedIndex! < _order.length
                        ? _order[_draggedIndex!].id
                        : null;
                if (draggedId != null) {
                  Log.info(
                    _tag,
                    'Nesting via drag',
                    data: {
                      'childId': draggedId,
                      'parentId': _nestTargetId!,
                    },
                  );
                  unawaited(
                    ref
                        .read(tileRepositoryProvider)
                        .nestInto(
                          childId: draggedId,
                          parentId: _nestTargetId!,
                        ),
                  );
                }
                _cancelHover();
                _draggedIndex = null;
                return;
              }

              // Normal reorder.
              setState(() {
                _order = reorderFn(_order);
              });
              Log.info(
                _tag,
                'Tiles reordered',
                data: {'count': '${_order.length}'},
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
                  crossAxisCount: _columns,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 16,
                  childAspectRatio: 0.72,
                ),
                children: children,
              );
            },
          ),
        );
      },
    );
  }
}

class _GroupTile extends ConsumerWidget {
  const _GroupTile({
    required this.group,
    super.key,
    this.isNested = false,
    this.isNestTarget = false,
    this.isNestCandidate = false,
  });

  final db.Tile group;

  /// Whether this tile is inside a parent (shows "move to home" option).
  final bool isNested;

  /// Whether this tile is the active nest target (hover timer fired).
  final bool isNestTarget;

  /// Whether this tile is being hovered as a potential nest target
  /// (hover started but timer hasn't fired yet).
  final bool isNestCandidate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final childTiles = ref.watch(childTilesProvider(group.id));
    final episodesAsync = ref.watch(tileItemsProvider(group.id));
    final hasChildren =
        childTiles.whenOrNull(data: (c) => c.isNotEmpty) ?? false;
    final count =
        hasChildren
            ? (childTiles.whenOrNull(data: (c) => c.length) ?? 0)
            : (episodesAsync.whenOrNull(data: (e) => e.length) ?? 0);

    return GestureDetector(
      onLongPress: () => _showContextMenu(context, ref),
      child: TileCard(
        key: Key('manage_tile_${group.id}'),
        title: group.title,
        episodeCount: count,
        coverUrl: group.coverUrl,
        contentType: group.contentType,
        isNestTarget: isNestTarget,
        isNestCandidate: isNestCandidate,
        onTap: () {
          if (hasChildren) {
            unawaited(
              context.push(AppRoutes.parentTileChildren(group.id)),
            );
          } else {
            unawaited(context.push(AppRoutes.parentTileEdit(group.id)));
          }
        },
      ),
    );
  }

  void _showContextMenu(BuildContext context, WidgetRef ref) {
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
                      unawaited(_showMoveIntoDialog(context, ref));
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
                    unawaited(_confirmDelete(context, ref));
                  },
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _showMoveIntoDialog(BuildContext context, WidgetRef ref) async {
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
                  // Show all root tiles except the one being moved.
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

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    await showDialog<void>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('Kachel löschen?'),
            content: Text(
              '„${group.title}" und alle enthaltenen Inhalte '
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
}
