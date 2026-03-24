import 'dart:async' show Timer, unawaited;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lauschi/core/catalog/catalog_service.dart' show ContentType;
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/tiles/widgets/tile_card.dart';

/// Duration to hold over a tile before nest mode activates.
const _nestHoldDuration = Duration(milliseconds: 800);

/// Long-press duration before drag starts.
const _longPressDuration = Duration(milliseconds: 300);

/// Item in the draggable grid.
class DraggableTileItem {
  const DraggableTileItem({
    required this.id,
    required this.title,
    this.coverUrl,
    this.episodeCount = 0,
    this.contentType = ContentType.hoerspiel,
    this.progress = 0,
    this.hasChildren = false,
  });

  final String id;
  final String title;
  final String? coverUrl;
  final int episodeCount;
  final ContentType contentType;
  final double progress;
  final bool hasChildren;
}

/// Android-launcher-style draggable grid.
///
/// Supports both reorder (drag to gap) and nest (hold over tile).
/// Tiles don't shift when you hover over them; they only shift when
/// you're in a gap between tiles.
class DraggableTileGrid extends StatefulWidget {
  const DraggableTileGrid({
    required this.items,
    required this.onReorder,
    required this.onNest,
    required this.onTap,
    required this.onLongPress,
    super.key,
  });

  final List<DraggableTileItem> items;
  final void Function(List<String> newOrder) onReorder;
  final void Function(String childId, String parentId) onNest;
  final void Function(String id) onTap;
  final void Function(String id) onLongPress;

  @override
  State<DraggableTileGrid> createState() => _DraggableTileGridState();
}

class _DraggableTileGridState extends State<DraggableTileGrid> {
  // ── Layout ────────────────────────────────────────────────────────
  int _columns = 3;
  double _cellWidth = 0;
  double _cellHeight = 0;
  static const _crossSpacing = 12.0;
  static const _mainSpacing = 16.0;
  static const _aspectRatio = 0.72;

  // ── Drag state ────────────────────────────────────────────────────
  String? _draggedId;
  Offset? _dragOffset; // global position of pointer
  int? _insertionIndex; // where to insert if dropped in a gap
  String? _nestTargetId; // tile being hovered for nesting
  bool _nestConfirmed = false; // 800ms threshold passed
  Timer? _nestTimer;
  String? _droppedId; // briefly set after drop for settle animation

  // ── Working order (mutated during drag for visual preview) ────────
  late List<DraggableTileItem> _order;

  @override
  void initState() {
    super.initState();
    _order = List.of(widget.items);
  }

  @override
  void didUpdateWidget(DraggableTileGrid old) {
    super.didUpdateWidget(old);
    // Only update if not mid-drag (avoid disrupting the drag visual).
    if (_draggedId == null) {
      _order = List.of(widget.items);
    }
  }

  @override
  void dispose() {
    _nestTimer?.cancel();
    super.dispose();
  }

  // ── Grid cell positions ───────────────────────────────────────────

  /// Compute the top-left offset of a cell at [index].
  Offset _cellOffset(int index) {
    final col = index % _columns;
    final row = index ~/ _columns;
    return Offset(
      AppSpacing.screenH + col * (_cellWidth + _crossSpacing),
      AppSpacing.md + row * (_cellHeight + _mainSpacing),
    );
  }

  /// Find which cell a local offset falls in. Returns null if in padding.
  /// Returns (index, isOverTile) where isOverTile indicates the pointer
  /// is over the tile body (not in the gap between tiles).
  (int index, bool isOverTile)? _hitTest(Offset local) {
    final x = local.dx - AppSpacing.screenH;
    final y = local.dy - AppSpacing.md;
    if (x < 0 || y < 0) return null;

    final colF = x / (_cellWidth + _crossSpacing);
    final rowF = y / (_cellHeight + _mainSpacing);
    final col = colF.floor();
    final row = rowF.floor();

    if (col >= _columns) return null;

    final index = row * _columns + col;
    if (index >= _order.length) return null;

    // Check if pointer is inside the cell body or in the gap.
    final cellX = x - col * (_cellWidth + _crossSpacing);
    final cellY = y - row * (_cellHeight + _mainSpacing);
    final isOverTile = cellX <= _cellWidth && cellY <= _cellHeight;

    return (index, isOverTile);
  }

  // ── Drag callbacks ────────────────────────────────────────────────

  void _onDragStart(String id) {
    unawaited(HapticFeedback.lightImpact());
    setState(() {
      _draggedId = id;
      _insertionIndex = null;
      _nestTargetId = null;
      _nestConfirmed = false;
      _droppedId = null;
    });
  }

  void _onDragUpdate(DragUpdateDetails details) {
    if (_draggedId == null) return;

    final gridBox = context.findRenderObject() as RenderBox?;
    if (gridBox == null) return;

    final local = gridBox.globalToLocal(details.globalPosition);
    _dragOffset = details.globalPosition;

    final hit = _hitTest(local);
    if (hit == null) {
      _clearNestTarget();
      setState(() => _insertionIndex = null);
      return;
    }

    final (index, isOverTile) = hit;
    final targetId = _order[index].id;

    if (targetId == _draggedId) {
      // Over ourselves, ignore.
      _clearNestTarget();
      setState(() => _insertionIndex = null);
      return;
    }

    if (isOverTile) {
      // Over a tile body: nest candidate.
      setState(() => _insertionIndex = null);
      if (_nestTargetId != targetId) {
        _clearNestTarget();
        _nestTargetId = targetId;
        setState(() {});
        _nestTimer = Timer(_nestHoldDuration, () {
          if (_nestTargetId == targetId && _draggedId != null) {
            setState(() => _nestConfirmed = true);
            unawaited(HapticFeedback.mediumImpact());
          }
        });
      }
    } else {
      // In a gap: reorder preview.
      _clearNestTarget();
      setState(() => _insertionIndex = index);
    }
  }

  void _onDragEnd() {
    if (_draggedId == null) return;

    final draggedId = _draggedId!;
    final wasNested = _nestConfirmed && _nestTargetId != null;
    final nestTarget = _nestTargetId;

    if (wasNested && nestTarget != null) {
      // Nest: dragged tile becomes child of target.
      widget.onNest(draggedId, nestTarget);
    } else if (_insertionIndex != null) {
      // Reorder: move draggedId to the gap position.
      final currentIndex = _order.indexWhere((t) => t.id == draggedId);
      if (currentIndex != -1 && currentIndex != _insertionIndex) {
        final item = _order.removeAt(currentIndex);
        // After removing, indices shift. If we're moving forward, the
        // target index is now one less than the visual gap position.
        var targetIdx = _insertionIndex!;
        if (targetIdx > currentIndex) targetIdx--;
        targetIdx = targetIdx.clamp(0, _order.length);
        _order.insert(targetIdx, item);
        widget.onReorder(_order.map((t) => t.id).toList());
      }
    }

    // Brief drop-settle animation: scale the dropped tile 0.95 → 1.0.
    _droppedId = draggedId;

    setState(() {
      _draggedId = null;
      _dragOffset = null;
      _insertionIndex = null;
    });
    _clearNestTarget();

    // Clear the drop animation after it plays.
    Future.delayed(const Duration(milliseconds: 250), () {
      if (mounted && _droppedId == draggedId) {
        setState(() => _droppedId = null);
      }
    });
  }

  void _clearNestTarget() {
    _nestTimer?.cancel();
    _nestTimer = null;
    if (_nestTargetId != null || _nestConfirmed) {
      setState(() {
        _nestTargetId = null;
        _nestConfirmed = false;
      });
    }
  }

  // ── Build ─────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
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

        final rowCount = (_order.length + _columns - 1) ~/ _columns;
        final totalHeight =
            rowCount * _cellHeight +
            (rowCount - 1) * _mainSpacing +
            AppSpacing.md * 2;

        return SizedBox(
          height: totalHeight,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              for (var i = 0; i < _order.length; i++)
                if (_order[i].id != _draggedId) _buildPositionedTile(i),

              // Drag feedback overlay.
              if (_draggedId != null && _dragOffset != null)
                _buildDragFeedback(),
            ],
          ),
        );
      },
    );
  }

  Widget _buildPositionedTile(int index) {
    final item = _order[index];
    final offset = _cellOffset(index);

    final isNestTarget = item.id == _nestTargetId;
    final isNestConfirmed = isNestTarget && _nestConfirmed;
    final isDropping = item.id == _droppedId;

    return AnimatedPositioned(
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
                : isNestConfirmed
                ? 1.08
                : isNestTarget
                ? 1.03
                : 1.0,
        duration: const Duration(milliseconds: 200),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          decoration: BoxDecoration(
            borderRadius: const BorderRadius.all(AppRadius.card),
            boxShadow:
                isNestConfirmed
                    ? [
                      BoxShadow(
                        color: AppColors.primary.withAlpha(80),
                        blurRadius: 16,
                        spreadRadius: 2,
                      ),
                    ]
                    : null,
            border:
                isNestConfirmed
                    ? Border.all(color: AppColors.primary, width: 2.5)
                    : isNestTarget
                    ? Border.all(
                      color: AppColors.primary.withAlpha(60),
                      width: 1.5,
                    )
                    : null,
          ),
          child: GestureDetector(
            onTap: () => widget.onTap(item.id),
            onLongPress: () => widget.onLongPress(item.id),
            child: LongPressDraggable<String>(
              data: item.id,
              delay: _longPressDuration,
              feedback: const SizedBox.shrink(), // we render our own
              childWhenDragging: Opacity(
                opacity: 0.3,
                child: _buildTileContent(item),
              ),
              onDragStarted: () => _onDragStart(item.id),
              onDragUpdate: _onDragUpdate,
              onDragEnd: (_) => _onDragEnd(),
              onDraggableCanceled: (_, _) => _onDragEnd(),
              child: _buildTileContent(item),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDragFeedback() {
    final item = _order.firstWhere((t) => t.id == _draggedId);
    final gridBox = context.findRenderObject() as RenderBox?;
    if (gridBox == null) return const SizedBox.shrink();

    final local = gridBox.globalToLocal(_dragOffset!);

    return Positioned(
      left: local.dx - _cellWidth / 2,
      top: local.dy - _cellHeight / 2,
      width: _cellWidth,
      height: _cellHeight,
      child: IgnorePointer(
        child: Transform.scale(
          scale: 1.05,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: const BorderRadius.all(AppRadius.card),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withAlpha(50),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: _buildTileContent(item),
          ),
        ),
      ),
    );
  }

  Widget _buildTileContent(DraggableTileItem item) {
    return TileCard(
      title: item.title,
      episodeCount: item.episodeCount,
      coverUrl: item.coverUrl,
      contentType: item.contentType,
      progress: item.progress,
      onTap: () {},
    );
  }
}
