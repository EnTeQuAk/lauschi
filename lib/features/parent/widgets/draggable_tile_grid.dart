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
  });

  final String id;
  final String title;
  final String? coverUrl;
  final int episodeCount;
  final ContentType contentType;
  final double progress;
  final int childCount;
  final List<String> childCoverUrls;
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
  });

  final List<DraggableTileItem> items;
  final void Function(List<String> newOrder) onReorder;
  final void Function(String childId, String parentId) onNest;
  final void Function(String id) onTap;
  final void Function(String id) onLongPress;

  /// Drop zones shown at the bottom during drag.
  final List<DropZoneConfig> dropZones;

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
  static const _aspectRatio = 0.72;

  // Drag state
  String? _draggedId;

  String? _nestTargetId;
  bool _nestConfirmed = false;
  Timer? _nestTimer;
  String? _droppedId;

  bool _orderChanged = false;
  DateTime? _nestIdleSince;
  int? _activeDropZone; // index of hovered drop zone, or null

  // Working order (mutated by swaps during drag)
  late List<DraggableTileItem> _order;

  @override
  void initState() {
    super.initState();
    _order = List.of(widget.items);
  }

  @override
  void didUpdateWidget(DraggableTileGrid old) {
    super.didUpdateWidget(old);
    if (_draggedId == null) {
      _order = List.of(widget.items);
    }
  }

  @override
  void dispose() {
    _nestTimer?.cancel();
    super.dispose();
  }

  // ── Hit test: which tile index is the pointer nearest to? ─────────

  int? _hitTest(Offset local) {
    final x = local.dx - AppSpacing.screenH;
    final y = local.dy - AppSpacing.md;
    if (x < 0 || y < 0) return null;

    final col = (x / (_cellWidth + _crossSpacing)).floor().clamp(
      0,
      _columns - 1,
    );
    final row = (y / (_cellHeight + _mainSpacing)).floor();
    if (row < 0) return null;

    final index = row * _columns + col;

    // Past the last tile: return null ("empty space").
    // The drag handler treats this as "move to end."
    if (index >= _order.length) return null;

    return (index >= 0) ? index : null;
  }

  Offset _cellOffset(int index) {
    final col = index % _columns;
    final row = index ~/ _columns;
    return Offset(
      AppSpacing.screenH + col * (_cellWidth + _crossSpacing),
      AppSpacing.md + row * (_cellHeight + _mainSpacing),
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

    final gridBox = context.findRenderObject() as RenderBox?;
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

    // Pointer is in empty space (past all tiles): move to end.
    if (index == null && _order.isNotEmpty) {
      if (_nestTargetId != null) _cancelNest();
      final draggedIdx = _order.indexWhere((t) => t.id == _draggedId);
      if (draggedIdx >= 0 && draggedIdx < _order.length - 1) {
        final dragged = _order.removeAt(draggedIdx);
        _order.add(dragged);
        _orderChanged = true;
        unawaited(HapticFeedback.selectionClick());
        Log.debug(_tag, 'Moved to END', data: {'from': '$draggedIdx'});
        setState(() {});
      }
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
      // Over our own slot. Cancel nest if active.
      if (_nestTargetId != null) _cancelNest();
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

      // Swap: dragged tile moves to this position, other tiles shift.
      final draggedIdx = _order.indexWhere((t) => t.id == _draggedId);
      if (draggedIdx >= 0 && draggedIdx != index) {
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

  /// Check if the pointer has been idle on the same target tile long
  /// enough to trigger nesting. Called every drag update.
  void _checkNestIdle(String targetId) {
    if (_nestConfirmed) return; // already confirmed
    if (_nestTargetId != targetId) {
      _nestIdleSince = DateTime.now();
      return;
    }
    if (_nestIdleSince == null) {
      _nestIdleSince = DateTime.now();
      return;
    }

    final idle = DateTime.now().difference(_nestIdleSince!);
    if (idle >= _nestDelay && _nestTimer == null) {
      // Pointer has been on this tile without swapping for 500ms.
      final targetTitle =
          _order.where((t) => t.id == targetId).firstOrNull?.title ?? '?';
      Log.info(
        _tag,
        'Nest CONFIRMED (idle ${idle.inMilliseconds}ms)',
        data: {
          'draggedId': _draggedId ?? '',
          'targetId': targetId,
          'targetTitle': targetTitle,
        },
      );
      setState(() => _nestConfirmed = true);
      unawaited(HapticFeedback.mediumImpact());
    }
  }

  void _cancelNest() {
    _nestTimer?.cancel();
    _nestTimer = null;
    _nestIdleSince = null;
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

  // ── Build ─────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            child: LayoutBuilder(
              builder: (context, constraints) {
                _columns =
                    constraints.maxWidth < 600
                        ? 3
                        : constraints.maxWidth < 900
                        ? 4
                        : 5;
                final gridWidth = constraints.maxWidth - AppSpacing.screenH * 2;
                _cellWidth =
                    (gridWidth - _crossSpacing * (_columns - 1)) / _columns;
                _cellHeight = _cellWidth / _aspectRatio;

                final rowCount =
                    _order.isEmpty
                        ? 0
                        : (_order.length + _columns - 1) ~/ _columns;
                final totalHeight =
                    rowCount == 0
                        ? 0.0
                        : rowCount * _cellHeight +
                            (rowCount - 1) * _mainSpacing +
                            AppSpacing.md * 2;

                return SizedBox(
                  height: totalHeight,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      for (var i = 0; i < _order.length; i++) _buildTile(i),
                    ],
                  ),
                );
              },
            ),
          ),
        ),

        // Drop zones at bottom (visible during drag).
        if (_draggedId != null && widget.dropZones.isNotEmpty)
          Padding(
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
          ),
      ],
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
