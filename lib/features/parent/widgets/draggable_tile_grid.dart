import 'dart:async' show Timer, unawaited;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lauschi/core/catalog/catalog_service.dart' show ContentType;
import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/tiles/widgets/tile_card.dart';

const _tag = 'DragGrid';

/// How long to hold over a tile before it becomes a nest target.
const _nestDelay = Duration(milliseconds: 500);

/// Long-press before drag starts.
const _longPressDelay = Duration(milliseconds: 300);

/// Configuration for a drop zone at the bottom of the grid.
class DropZoneConfig {
  const DropZoneConfig({
    required this.label,
    required this.icon,
    required this.onDrop,
    this.color = AppColors.primary,
  });

  final String label;
  final IconData icon;
  final void Function(String tileId) onDrop;
  final Color color;
}

/// Whether a grid cell renders a series tile (with stacked-card art) or
/// a single ungrouped episode (no stack). Drives layout partition,
/// drop dispatch, and per-cell visual treatment.
enum GridItemKind { tile, episode }

/// Grid item data.
class DraggableTileItem {
  const DraggableTileItem({
    required this.id,
    required this.title,
    this.coverUrl,
    this.episodeCount = 0,
    this.contentType = ContentType.hoerspiel,
    this.progress = 0,
    this.childCount = 0,
    this.childCoverUrls = const [],
    this.kind = GridItemKind.tile,
  });

  final String id;
  final String title;
  final String? coverUrl;
  final int episodeCount;
  final ContentType contentType;
  final double progress;
  final int childCount;
  final List<String> childCoverUrls;
  final GridItemKind kind;
}

/// Drag grid with swap-on-hover reorder and hold-to-nest.
///
/// UX: dragging over another tile swaps positions immediately (reorder).
/// Holding still over a tile for 500ms highlights it for nesting.
/// Releasing commits the current order or nests, depending on state.
class DraggableTileGrid extends StatefulWidget {
  const DraggableTileGrid({
    required this.items,
    required this.onReorder,
    required this.onNest,
    required this.onTap,
    required this.onLongPress,
    super.key,
    this.dropZones = const [],
    this.shrinkWrap = false,
  });

  final List<DraggableTileItem> items;
  final void Function(List<String> newOrder) onReorder;
  final void Function(String childId, String parentId) onNest;
  final void Function(String id) onTap;
  final void Function(String id) onLongPress;

  /// Drop zones shown at the bottom during drag.
  final List<DropZoneConfig> dropZones;

  /// When true, the grid sizes itself to its content (height comes from
  /// row count and tile aspect ratio) and doesn't try to fill the parent.
  /// Use when placing the grid inside an unbounded parent like
  /// [SliverToBoxAdapter] or another scroll view. The parent then handles
  /// scrolling instead of the grid's internal [SingleChildScrollView].
  final bool shrinkWrap;

  @override
  State<DraggableTileGrid> createState() => _DraggableTileGridState();
}

class _DraggableTileGridState extends State<DraggableTileGrid> {
  // Layout
  int _columns = 3;
  double _cellWidth = 0;
  double _cellHeight = 0;
  static const _crossSpacing = 10.0;
  static const _mainSpacing = 14.0;
  static const _aspectRatio = 0.7;

  /// Vertical band between the tile block and the episode block. Holds
  /// the "N einzelne Folgen" count line plus a centered helper hint
  /// (the analogue of the "Halten & ziehen…" hint above the grid).
  /// Only rendered when [_showDivider] is true.
  static const _dividerBandHeight = 64.0;

  // Drag state
  String? _draggedId;

  String? _nestTargetId;
  bool _nestConfirmed = false;
  Timer? _nestTimer;
  String? _droppedId;

  bool _orderChanged = false;
  int? _activeDropZone; // index of hovered drop zone, or null

  // Working order (mutated by swaps during drag)
  late List<DraggableTileItem> _order;

  /// Attached to the inner SizedBox that wraps the cell [Stack]. Used to
  /// convert pointer positions during a drag — the SizedBox is what
  /// [_cellOffset] / [_hitTest] expect coordinates relative to, and
  /// using its render box makes [SingleChildScrollView] scroll offsets
  /// fall out automatically.
  final _gridKey = GlobalKey();

  /// Index of the first episode in [_order]. Equals the number of tile
  /// items. Items at index < _boundary are tile-kind, items at index >=
  /// _boundary are episode-kind. Cross-kind swaps are forbidden so this
  /// stays constant during a drag.
  int _boundary = 0;

  bool get _showDivider => _boundary > 0 && _boundary < _order.length;

  void _recomputeBoundary() {
    _boundary = _order.indexWhere((t) => t.kind == GridItemKind.episode);
    if (_boundary < 0) _boundary = _order.length; // no episodes
  }

  @override
  void initState() {
    super.initState();
    _order = List.of(widget.items);
    _recomputeBoundary();
  }

  @override
  void didUpdateWidget(DraggableTileGrid old) {
    super.didUpdateWidget(old);
    if (_draggedId == null) {
      _order = List.of(widget.items);
      _recomputeBoundary();
    }
  }

  @override
  void dispose() {
    _nestTimer?.cancel();
    super.dispose();
  }

  // ── Hit test: which tile index is the pointer nearest to? ─────────

  /// Y offset (from grid top, excluding marginTop) at which the episode
  /// block begins. Zero when the grid is single-block (only tiles, only
  /// episodes, or empty).
  double get _episodeBlockYOffset {
    if (!_showDivider) return 0;
    final tileRows = (_boundary + _columns - 1) ~/ _columns;
    return tileRows * _cellHeight +
        (tileRows - 1) * _mainSpacing +
        _dividerBandHeight;
  }

  int? _hitTest(Offset local) {
    final x = local.dx - AppSpacing.screenH;
    final y = local.dy - AppSpacing.md;
    if (x < 0 || y < 0) return null;

    final col = (x / (_cellWidth + _crossSpacing)).floor().clamp(
      0,
      _columns - 1,
    );

    if (_showDivider) {
      final tileRows = (_boundary + _columns - 1) ~/ _columns;
      final tileBlockH = tileRows * _cellHeight + (tileRows - 1) * _mainSpacing;

      if (y < tileBlockH) {
        // Pointer over the tile block (rows or inter-row gaps).
        final row = (y / (_cellHeight + _mainSpacing)).floor();
        final index = row * _columns + col;
        // Empty slot at end of the last partial row → no target.
        if (index >= _boundary) return null;
        return (index >= 0) ? index : null;
      }
      if (y < tileBlockH + _dividerBandHeight) {
        // Pointer inside the divider band — neither swap nor nest.
        return null;
      }
      // Pointer in the episode block.
      final yEp = y - tileBlockH - _dividerBandHeight;
      final row = (yEp / (_cellHeight + _mainSpacing)).floor();
      if (row < 0) return null;
      final episodeIdx = row * _columns + col;
      final absoluteIdx = _boundary + episodeIdx;
      if (absoluteIdx >= _order.length) return null;
      return absoluteIdx;
    }

    // Single-block grid: same math as before.
    final row = (y / (_cellHeight + _mainSpacing)).floor();
    if (row < 0) return null;
    final index = row * _columns + col;
    if (index >= _order.length) return null;
    return (index >= 0) ? index : null;
  }

  Offset _cellOffset(int index) {
    final col = index % _columns;
    if (index < _boundary) {
      final row = index ~/ _columns;
      return Offset(
        AppSpacing.screenH + col * (_cellWidth + _crossSpacing),
        AppSpacing.md + row * (_cellHeight + _mainSpacing),
      );
    }
    final episodeIdx = index - _boundary;
    final row = episodeIdx ~/ _columns;
    return Offset(
      AppSpacing.screenH + col * (_cellWidth + _crossSpacing),
      AppSpacing.md + _episodeBlockYOffset + row * (_cellHeight + _mainSpacing),
    );
  }

  // ── Drag lifecycle ────────────────────────────────────────────────

  int _dragUpdateCount = 0;

  void _onDragStart(String id) {
    if (_draggedId != null) {
      Log.warn(_tag, 'Double drag blocked', data: {'attempted': id});
      return;
    }
    _nestTimer?.cancel();
    _orderChanged = false;
    _dragUpdateCount = 0;
    unawaited(HapticFeedback.lightImpact());
    final title = _order.firstWhere((t) => t.id == id).title;
    Log.info(
      _tag,
      'Drag START',
      data: {
        'id': id,
        'title': title,
      },
    );
    Log.debug(
      _tag,
      'Grid layout',
      data: {
        'columns': '$_columns',
        'cellW': _cellWidth.toStringAsFixed(1),
        'cellH': _cellHeight.toStringAsFixed(1),
        'tileCount': '${_order.length}',
      },
    );
    setState(() {
      _draggedId = id;
      _nestTargetId = null;
      _nestConfirmed = false;
      _droppedId = null;
    });
  }

  void _onDragUpdate(DragUpdateDetails details) {
    if (_draggedId == null) {
      Log.warn(_tag, 'DragUpdate but no draggedId');
      return;
    }

    _dragUpdateCount++;

    // Convert via the inner grid SizedBox, not the State's outer Column.
    // The Column doesn't move when the user scrolls, but the SizedBox
    // does — so using its render box collapses any scroll offset into
    // the conversion. With the previous outer-context lookup, a scroll
    // of N px made every hit-test land N px above the finger, which on
    // a mixed grid showed up as drags in the episode lane "activating"
    // tiles in the upper block.
    final gridBox = _gridKey.currentContext?.findRenderObject() as RenderBox?;
    if (gridBox == null) return;
    final local = gridBox.globalToLocal(details.globalPosition);

    // Check if pointer is in any drop zone (bottom of screen).
    if (widget.dropZones.isNotEmpty) {
      final screenHeight = MediaQuery.of(context).size.height;
      final zoneCount = widget.dropZones.length;
      const zoneHeight = 56.0;
      final zonesTop = screenHeight - zoneCount * zoneHeight;
      final globalY = details.globalPosition.dy;

      if (globalY > zonesTop) {
        final zoneIdx = ((globalY - zonesTop) / zoneHeight).floor().clamp(
          0,
          zoneCount - 1,
        );
        if (_activeDropZone != zoneIdx) {
          setState(() => _activeDropZone = zoneIdx);
          _cancelNest();
          unawaited(HapticFeedback.selectionClick());
        }
        return; // don't process grid hit-test
      } else if (_activeDropZone != null) {
        setState(() => _activeDropZone = null);
      }
    }

    final index = _hitTest(local);

    // Pointer is in empty space (past the dragged kind's block): move
    // to the end of that block. The shift is kind-aware so dragging
    // off-grid never moves a tile into the episode lane (or vice versa).
    if (index == null && _order.isNotEmpty) {
      if (_nestTargetId != null) _cancelNest();
      _maybeMoveToBlockEnd(local);
    }

    // Log roughly once per second during drag.
    if (_dragUpdateCount % 60 == 0) {
      Log.debug(
        _tag,
        'Drag #$_dragUpdateCount',
        data: {
          'local':
              '(${local.dx.toStringAsFixed(0)}, ${local.dy.toStringAsFixed(0)})',
          'hitIdx': index != null ? '$index (${_order[index].title})' : 'null',
          'nestTarget': _nestTargetId ?? 'none',
          'confirmed': '$_nestConfirmed',
        },
      );
    }

    if (index == null) {
      if (!_nestConfirmed) _cancelNest();
      return;
    }

    final targetId = _order[index].id;
    if (targetId == _draggedId) {
      // Pointer is over the dragged item's current slot. Two cases:
      //   1. We have no active target — drag just started, no swap yet.
      //      Nothing to do.
      //   2. We have an active target. After a backward swap (dragging
      //      from a higher index to a lower one), the dragged item lands
      //      AT the original target's slot while the target shifts one
      //      slot over. The pointer hit-tests the dragged item, but the
      //      user's intent is "I'm hovering on the target". Keep the
      //      nest idle timer running on the original target so
      //      hold-to-merge can still confirm on a backward drag.
      if (_nestTargetId != null) {
        _checkNestIdle(_nestTargetId!);
      }
      return;
    }

    // If nest is confirmed but pointer moved to a DIFFERENT tile, cancel it.
    if (_nestConfirmed && _nestTargetId != targetId) {
      Log.debug(_tag, 'Nest unlock (moved to different tile)');
      _cancelNest();
    }
    // If still on the confirmed target, stay locked.
    if (_nestConfirmed && _nestTargetId == targetId) return;

    // Moving to a different tile: swap immediately (reorder).
    // The nest timer only starts AFTER the swap, when the pointer
    // settles on the new neighbor. This prevents accidental nesting
    // when dragging quickly through tiles.
    if (_nestTargetId != targetId) {
      _cancelNest();
      _nestTargetId = targetId;
      final targetTitle = _order[index].title;

      final draggedIdx = _order.indexWhere((t) => t.id == _draggedId);
      final draggedKind =
          draggedIdx >= 0 ? _order[draggedIdx].kind : GridItemKind.tile;
      final targetKind = _order[index].kind;

      // Cross-kind hover: don't reorder. The hold-to-nest path
      // (started by _checkNestIdle below) is what handles merging
      // across the divider.
      if (draggedKind == targetKind && draggedIdx >= 0 && draggedIdx != index) {
        // Swap: dragged tile moves to this position, other tiles shift.
        final dragged = _order.removeAt(draggedIdx);
        final insertAt = (index > draggedIdx ? index - 1 : index).clamp(
          0,
          _order.length,
        );
        _order.insert(insertAt, dragged);
        _orderChanged = true;
        unawaited(HapticFeedback.selectionClick());
        Log.debug(
          _tag,
          'SWAP',
          data: {
            'from': '$draggedIdx',
            'to': '$insertAt',
            'target': targetTitle,
          },
        );
        setState(() {});
      }

      // DON'T start nest timer yet. Wait until the pointer
      // stops moving (tracked by _lastMoveTime in the next update).
      // The nest timer starts in _checkNestIdle().
    }

    // Track pointer velocity. If the pointer hasn't moved to a
    // different tile for 500ms, THEN start the nest confirmation.
    _checkNestIdle(targetId);
  }

  void _onDragEnd() {
    if (_draggedId == null) {
      Log.warn(_tag, 'Drag END but no drag active');
      return;
    }

    final draggedId = _draggedId!;
    final wasNested = _nestConfirmed && _nestTargetId != null;

    Log.info(
      _tag,
      'Drag END',
      data: {
        'draggedId': draggedId,
        'wasNested': '$wasNested',
        'nestTarget': _nestTargetId ?? 'none',
        'orderChanged': '$_orderChanged',
        'updates': '$_dragUpdateCount',
      },
    );

    if (_activeDropZone != null && _activeDropZone! < widget.dropZones.length) {
      final zone = widget.dropZones[_activeDropZone!];
      Log.info(
        _tag,
        'DROP ZONE action',
        data: {
          'tileId': draggedId,
          'zone': zone.label,
        },
      );
      zone.onDrop(draggedId);
    } else if (wasNested) {
      Log.info(
        _tag,
        'NESTING',
        data: {
          'childId': draggedId,
          'parentId': _nestTargetId!,
        },
      );
      widget.onNest(draggedId, _nestTargetId!);
    } else if (_orderChanged) {
      Log.info(
        _tag,
        'REORDER committed',
        data: {
          'order': _order.map((t) => t.title).join(', '),
        },
      );
      widget.onReorder(_order.map((t) => t.id).toList());
    } else {
      Log.debug(_tag, 'Drop (no change)');
    }

    _droppedId = draggedId;
    setState(() {
      _draggedId = null;
      _activeDropZone = null;
    });
    _cancelNest();

    Future.delayed(const Duration(milliseconds: 200), () {
      if (mounted && _droppedId == draggedId) {
        setState(() => _droppedId = null);
      }
    });
  }

  /// Arm (or keep armed) the nest-confirm timer on the given target.
  ///
  /// Called from every drag update on a valid target. If a timer is
  /// already counting down on the same target, this is a no-op — the
  /// timer keeps running. If the target changed, the caller is expected
  /// to have called [_cancelNest] first so this starts a fresh timer.
  ///
  /// Using a [Timer] (rather than polling [DateTime.now] between drag
  /// updates) makes the confirm window deterministic under the test
  /// binding's fake clock: `tester.pump(_nestDelay)` advances it
  /// exactly the way real wall-clock time does in production.
  void _checkNestIdle(String targetId) {
    if (_nestConfirmed) return;
    if (_nestTargetId != targetId) return; // defensive — caller misalignment
    if (_nestTimer != null) return;
    _nestTimer = Timer(_nestDelay, () {
      if (!mounted) return;
      if (_nestTargetId != targetId) return;
      final targetTitle =
          _order.where((t) => t.id == targetId).firstOrNull?.title ?? '?';
      Log.info(
        _tag,
        'Nest CONFIRMED',
        data: {
          'draggedId': _draggedId ?? '',
          'targetId': targetId,
          'targetTitle': targetTitle,
        },
      );
      setState(() => _nestConfirmed = true);
      unawaited(HapticFeedback.mediumImpact());
    });
  }

  void _cancelNest() {
    _nestTimer?.cancel();
    _nestTimer = null;
    if (_nestTargetId != null || _nestConfirmed) {
      Log.debug(
        _tag,
        'Nest cancelled',
        data: {
          'target': _nestTargetId ?? 'none',
          'wasConfirmed': '$_nestConfirmed',
        },
      );
      setState(() {
        _nestTargetId = null;
        _nestConfirmed = false;
      });
    }
  }

  /// Empty-space drag handler. If the pointer is below the dragged
  /// kind's last cell, slide the item to that block's end. Cross-kind
  /// is never crossed — a tile cannot move into the episode lane via
  /// this path, and vice versa.
  void _maybeMoveToBlockEnd(Offset local) {
    final draggedIdx = _order.indexWhere((t) => t.id == _draggedId);
    if (draggedIdx < 0) return;
    final dragged = _order[draggedIdx];

    // End-of-block index, in the current _order indexing.
    final endOfBlock =
        dragged.kind == GridItemKind.tile ? _boundary - 1 : _order.length - 1;
    if (endOfBlock < 0 || draggedIdx == endOfBlock) return;

    // Only move-to-end when the pointer is past the last row of the
    // dragged kind's block. Pointer above that row (e.g. an empty slot
    // in a middle partial row) does nothing — preserves position.
    final lastCellBottom = _cellOffset(endOfBlock).dy + _cellHeight;
    if (local.dy < lastCellBottom) return;

    final removed = _order.removeAt(draggedIdx);
    // After removal, items at index > draggedIdx shifted down by one.
    // For a same-kind move-to-end, the new endOfBlock is endOfBlock - 1
    // if draggedIdx was before it (always true since dragged was in the
    // block), so insert at that adjusted index.
    final insertAt = endOfBlock - 1;
    _order.insert(insertAt.clamp(0, _order.length), removed);
    _orderChanged = true;
    unawaited(HapticFeedback.selectionClick());
    Log.debug(
      _tag,
      'Moved to END of block',
      data: {
        'kind': dragged.kind.name,
        'from': '$draggedIdx',
        'to': '$insertAt',
      },
    );
    setState(() {});
  }

  // ── Build ─────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // The grid contents: a Stack of positioned tiles inside a SizedBox
    // whose height is calculated from the number of rows. Width is
    // discovered from the parent's [BoxConstraints.maxWidth].
    final grid = LayoutBuilder(
      builder: (context, constraints) {
        _columns =
            constraints.maxWidth < 600
                ? 3
                : constraints.maxWidth < 900
                ? 4
                : 5;
        final gridWidth = constraints.maxWidth - AppSpacing.screenH * 2;
        _cellWidth = (gridWidth - _crossSpacing * (_columns - 1)) / _columns;
        _cellHeight = _cellWidth / _aspectRatio;

        final tileRows =
            _boundary == 0 ? 0 : (_boundary + _columns - 1) ~/ _columns;
        final episodeCount = _order.length - _boundary;
        final episodeRows =
            episodeCount <= 0 ? 0 : (episodeCount + _columns - 1) ~/ _columns;

        var totalHeight = AppSpacing.md * 2;
        if (tileRows > 0) {
          totalHeight += tileRows * _cellHeight + (tileRows - 1) * _mainSpacing;
        }
        if (episodeRows > 0) {
          if (tileRows > 0) totalHeight += _dividerBandHeight;
          totalHeight +=
              episodeRows * _cellHeight + (episodeRows - 1) * _mainSpacing;
        }

        return SizedBox(
          key: _gridKey,
          height: totalHeight,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              if (_showDivider)
                Positioned(
                  left: AppSpacing.screenH,
                  right: AppSpacing.screenH,
                  top:
                      AppSpacing.md +
                      tileRows * _cellHeight +
                      (tileRows - 1) * _mainSpacing,
                  height: _dividerBandHeight,
                  child: _BoundaryLabel(count: episodeCount),
                ),
              for (var i = 0; i < _order.length; i++) _buildTile(i),
            ],
          ),
        );
      },
    );

    final showDropZones = _draggedId != null && widget.dropZones.isNotEmpty;

    if (widget.shrinkWrap) {
      // Caller provides unbounded height (e.g. SliverToBoxAdapter). Don't
      // wrap in Expanded — the SizedBox inside [grid] sets the height,
      // and the outer scroll view handles overflow.
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          grid,
          if (showDropZones) _buildDropZonesPadding(context),
        ],
      );
    }

    // Bounded mode: take all available height. The internal scroll view
    // handles overflow when there are more rows than fit on screen.
    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(child: grid),
        ),
        if (showDropZones) _buildDropZonesPadding(context),
      ],
    );
  }

  Widget _buildDropZonesPadding(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).padding.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < widget.dropZones.length; i++)
            _buildDropZone(widget.dropZones[i], i),
        ],
      ),
    );
  }

  Widget _buildTile(int index) {
    final item = _order[index];
    final offset = _cellOffset(index);
    final isNestTarget = item.id == _nestTargetId && _nestConfirmed;
    final isNestCandidate = item.id == _nestTargetId && !_nestConfirmed;
    final isDropping = item.id == _droppedId;

    return AnimatedPositioned(
      key: ValueKey(item.id),
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
      left: offset.dx,
      top: offset.dy,
      width: _cellWidth,
      height: _cellHeight,
      child: AnimatedScale(
        scale:
            isDropping
                ? 0.95
                : isNestTarget
                ? 1.08
                : isNestCandidate
                ? 1.03
                : 1.0,
        duration: const Duration(milliseconds: 200),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          decoration: BoxDecoration(
            borderRadius: const BorderRadius.all(AppRadius.card),
            boxShadow:
                isNestTarget
                    ? [
                      BoxShadow(
                        color: AppColors.primary.withAlpha(80),
                        blurRadius: 16,
                        spreadRadius: 2,
                      ),
                    ]
                    : null,
            border:
                isNestTarget
                    ? Border.all(color: AppColors.primary, width: 2.5)
                    : isNestCandidate
                    ? Border.all(
                      color: AppColors.primary.withAlpha(60),
                      width: 1.5,
                    )
                    : null,
          ),
          child: LongPressDraggable<String>(
            data: item.id,
            delay: _longPressDelay,
            feedback: SizedBox(
              width: _cellWidth > 0 ? _cellWidth * 1.08 : 100,
              height: _cellHeight > 0 ? _cellHeight * 1.08 : 140,
              child: Material(
                color: Colors.transparent,
                borderRadius: const BorderRadius.all(AppRadius.card),
                elevation: 12,
                child: _tileContent(item),
              ),
            ),
            childWhenDragging: Opacity(
              opacity: 0.3,
              child: _tileContent(item),
            ),
            onDragStarted: () => _onDragStart(item.id),
            onDragUpdate: _onDragUpdate,
            onDragEnd: (_) => _onDragEnd(),
            onDraggableCanceled: (_, _) => _onDragEnd(),
            child: _TappableTile(
              onTap: () => widget.onTap(item.id),
              child: _tileContent(item),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDropZone(DropZoneConfig zone, int index) {
    final isActive = _activeDropZone == index;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      height: 52,
      decoration: BoxDecoration(
        color: isActive ? zone.color : zone.color.withAlpha(20),
        border: Border(
          top: BorderSide(
            color: isActive ? zone.color : zone.color.withAlpha(60),
            width: isActive ? 2 : 1,
          ),
        ),
      ),
      child: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              zone.icon,
              size: 20,
              color: isActive ? Colors.white : zone.color,
            ),
            const SizedBox(width: 8),
            Text(
              zone.label,
              style: TextStyle(
                fontFamily: 'Nunito',
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: isActive ? Colors.white : zone.color,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tileContent(DraggableTileItem item) {
    return TileCard(
      title: item.title,
      episodeCount: item.episodeCount,
      coverUrl: item.coverUrl,
      contentType: item.contentType,
      progress: item.progress,
      childCount: item.childCount,
      childCoverUrls: item.childCoverUrls,
      onTap: () {},
    );
  }
}

/// Section break between the tile block and the episode block.
///
/// Renders a hairline with an inline label so parents can see at a
/// glance which row is series tiles vs single episodes. Only shown
/// when both blocks have at least one cell. The parent [Positioned]
/// fixes the band's height to [_DraggableTileGridState._dividerBandHeight];
/// [Center] keeps the row vertically centered without consuming that
/// height with inner padding.
class _BoundaryLabel extends StatelessWidget {
  const _BoundaryLabel({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final lineColor = AppColors.textSecondary.withAlpha(60);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(child: Container(height: 1, color: lineColor)),
              const SizedBox(width: AppSpacing.sm),
              const Icon(
                Icons.layers_clear_rounded,
                size: 14,
                color: AppColors.textSecondary,
              ),
              const SizedBox(width: 4),
              Text(
                count == 1 ? '1 einzelne Folge' : '$count einzelne Folgen',
                style: const TextStyle(
                  fontFamily: 'Nunito',
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textSecondary,
                  letterSpacing: 0.4,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(child: Container(height: 1, color: lineColor)),
            ],
          ),
          const SizedBox(height: 4),
          // Style mirrors the top-of-screen _DragHint exactly (same
          // touch_app_rounded icon, 12pt Nunito, faded textSecondary)
          // so parents read the two hints as a pair. The Row is centered
          // here while the top one is left-aligned — the only intentional
          // difference, because the divider band frames this hint.
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.touch_app_rounded,
                size: 14,
                color: AppColors.textSecondary.withAlpha(150),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  'Auf eine Kachel ziehen oder zwei zu einer neuen '
                  'Kachel verbinden',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: 'Nunito',
                    fontSize: 12,
                    color: AppColors.textSecondary.withAlpha(150),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Detects taps without competing with LongPressDraggable's gesture arena.
///
/// Uses pointer timing: if pointer down → pointer up within 300ms and
/// didn't move significantly, it's a tap. This bypasses the gesture
/// arena entirely since Listener doesn't participate in it.
class _TappableTile extends StatefulWidget {
  const _TappableTile({required this.onTap, required this.child});

  final VoidCallback onTap;
  final Widget child;

  @override
  State<_TappableTile> createState() => _TappableTileState();
}

class _TappableTileState extends State<_TappableTile> {
  Offset? _downPos;
  DateTime? _downTime;

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (e) {
        _downPos = e.localPosition;
        _downTime = DateTime.now();
      },
      onPointerUp: (e) {
        if (_downPos == null || _downTime == null) return;
        final dt = DateTime.now().difference(_downTime!);
        final dist = (e.localPosition - _downPos!).distance;
        // Quick tap: under 300ms and didn't move more than 20px.
        if (dt.inMilliseconds < 300 && dist < 20) {
          widget.onTap();
        }
        _downPos = null;
        _downTime = null;
      },
      onPointerCancel: (_) {
        _downPos = null;
        _downTime = null;
      },
      child: widget.child,
    );
  }
}
