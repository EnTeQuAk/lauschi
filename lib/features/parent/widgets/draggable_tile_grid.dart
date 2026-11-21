import 'dart:async' show Timer, unawaited;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lauschi/core/catalog/catalog_service.dart' show ContentType;
import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/tiles/widgets/tile_card.dart';

const _tag = 'DragGrid';

/// How long to hold still on the middle of a tile before it becomes a
/// nest target.
const _nestDelay = Duration(milliseconds: 500);

/// How long to hold still on the edge of a tile before the dragged tile
/// moves next to it. While the pointer moves nothing changes, so passing
/// over other tiles doesn't push the target away.
const _moveDelay = Duration(milliseconds: 250);

/// How far the pointer may wander and still count as holding still.
const _holdSlop = 10.0;

/// Where a tile's middle starts, as a share of its width from each edge
/// of the square art. The middle makes a folder, the rest moves the
/// dragged tile next to it.
const _middleStart = 0.25;

/// The parts of a cell a drag can be over.
enum _CellZone { middle, leftEdge, rightEdge, aboveOrBelow }

/// Where the dragged item goes: right before or after the target.
typedef _Move = ({String targetId, bool after});

/// The pointer resting on one thing ([key]) during a drag. Calls [onFire]
/// after [delay], with [key] still set, unless the pointer moves on to
/// another key or wanders more than [_holdSlop] from where it came to
/// rest.
///
/// A [Timer] rather than comparing [DateTime.now] between drag updates
/// keeps it deterministic under the test binding's fake clock:
/// `tester.pump(delay)` advances it the way real time does.
class _Hold<K> {
  _Hold(this.delay, this.onFire);

  final Duration delay;
  final VoidCallback onFire;

  K? key;
  Offset? _restingAt;
  Timer? _timer;

  void restOn(K key, Offset position) {
    if (this.key == key && (position - _restingAt!).distance <= _holdSlop) {
      return;
    }
    _timer?.cancel();
    this.key = key;
    _restingAt = position;
    _timer = Timer(delay, onFire);
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
    key = null;
    _restingAt = null;
  }
}

/// Long-press before drag starts.
const _longPressDelay = Duration(milliseconds: 300);

/// Rendered height of one bottom drop zone. The drag hit-test and the
/// visual zones must agree on this.
const dropZoneHeight = 52.0;

/// Which drop zone a global Y coordinate falls in, or null.
///
/// The zones render stacked directly above the bottom safe-area inset
/// (see `_buildDropZonesPadding`), so the hit-test region is
/// `[screenHeight - bottomInset - zoneCount*height, screenHeight -
/// bottomInset)`, not down to the raw screen bottom. Using the screen
/// bottom left the visible top of each zone dead and let the safe-area
/// padding below the zones falsely activate the last one.
int? dropZoneIndexAt({
  required double globalY,
  required double screenHeight,
  required double bottomInset,
  required int zoneCount,
}) {
  if (zoneCount == 0) return null;
  final bottom = screenHeight - bottomInset;
  final top = bottom - zoneCount * dropZoneHeight;
  if (globalY < top || globalY >= bottom) return null;
  return ((globalY - top) / dropZoneHeight).floor().clamp(0, zoneCount - 1);
}

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

  /// See [TileCard.childCoverUrls].
  final List<String?> childCoverUrls;
  final GridItemKind kind;
}

/// Drag grid that reorders and nests like a phone's home screen.
///
/// UX: nothing changes while the pointer moves. Resting on the left or
/// right edge of another tile moves the dragged tile next to it, on that
/// side, so a tile only yields once you pass its middle. Resting on the
/// middle of a tile for 500ms highlights it for nesting. Releasing on an
/// edge places the tile there, on a highlighted tile nests, otherwise it
/// commits the current order.
class DraggableTileGrid extends StatefulWidget {
  const DraggableTileGrid({
    required this.items,
    required this.onReorder,
    required this.onNest,
    required this.onTap,
    super.key,
    this.dropZones = const [],
  });

  final List<DraggableTileItem> items;
  final void Function(List<String> newOrder) onReorder;
  final void Function(String childId, String parentId) onNest;
  final void Function(String id) onTap;

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
  static const _aspectRatio = 0.7;

  /// Vertical band between the tile block and the episode block. Holds
  /// the "N einzelne Folgen" count line plus a centered helper hint
  /// (the analogue of the "Halten & ziehen…" hint above the grid).
  /// Only rendered when [_showDivider] is true.
  static const _dividerBandHeight = 64.0;

  // Drag state
  String? _draggedId;

  /// Resting on the middle of a tile: its id is the nest target.
  late final _nestHold = _Hold<String>(_nestDelay, _confirmNest);
  bool _nestConfirmed = false;

  /// Resting on the edge of a tile: where the dragged item would go.
  late final _moveHold = _Hold<_Move>(_moveDelay, _applyPendingMove);
  String? _droppedId;

  bool _orderChanged = false;
  int? _activeDropZone; // index of hovered drop zone, or null

  // Working order, rearranged while dragging
  late List<DraggableTileItem> _order;

  /// Attached to the inner SizedBox that wraps the cell [Stack]. Used to
  /// convert pointer positions during a drag — the SizedBox is what
  /// [_cellOffset] / [_hitTest] expect coordinates relative to, and
  /// using its render box makes [SingleChildScrollView] scroll offsets
  /// fall out automatically.
  final _gridKey = GlobalKey();

  /// Index of the first episode in [_order]. Equals the number of tile
  /// items. Items at index < _boundary are tile-kind, items at index >=
  /// _boundary are episode-kind. No item moves across it, so this stays
  /// constant during a drag.
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
    _nestHold.cancel();
    _moveHold.cancel();
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
        // Pointer inside the divider band: neither move nor nest.
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

  int get _draggedIndex => _order.indexWhere((t) => t.id == _draggedId);

  void _onDragStart(String id) {
    if (_draggedId != null) {
      Log.warn(_tag, 'Double drag blocked', data: {'attempted': id});
      return;
    }
    _nestHold.cancel();
    _moveHold.cancel();
    _orderChanged = false;
    _dragUpdateCount = 0;
    unawaited(HapticFeedback.lightImpact());
    final title = _order.firstWhere((t) => t.id == id).title;
    Log.info(_tag, 'Drag START', data: {'id': id, 'title': title});
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

    // Check if pointer is in any drop zone (above the bottom safe area).
    if (widget.dropZones.isNotEmpty) {
      final media = MediaQuery.of(context);
      final zoneIdx = dropZoneIndexAt(
        globalY: details.globalPosition.dy,
        screenHeight: media.size.height,
        bottomInset: media.padding.bottom,
        zoneCount: widget.dropZones.length,
      );

      if (zoneIdx != null) {
        if (_activeDropZone != zoneIdx) {
          setState(() => _activeDropZone = zoneIdx);
          _cancelNest();
          _moveHold.cancel();
          unawaited(HapticFeedback.selectionClick());
        }
        return; // don't process grid hit-test
      } else if (_activeDropZone != null) {
        setState(() => _activeDropZone = null);
      }
    }

    final index = _hitTest(local);

    // Log roughly once per second during drag.
    if (_dragUpdateCount % 60 == 0) {
      Log.debug(
        _tag,
        'Drag #$_dragUpdateCount',
        data: {
          'local':
              '(${local.dx.toStringAsFixed(0)}, ${local.dy.toStringAsFixed(0)})',
          'hitIdx': index != null ? '$index (${_order[index].title})' : 'null',
          'nestTarget': _nestHold.key ?? 'none',
          'confirmed': '$_nestConfirmed',
        },
      );
    }

    if (index == null) {
      _cancelNest();
      _holdForBlockEnd(local);
      return;
    }

    final target = _order[index];
    final draggedIdx = _draggedIndex;
    if (draggedIdx < 0) return;

    // Over its own slot: after a move the dragged tile sits under the
    // finger, and there's no other tile to nest into or move next to.
    if (draggedIdx == index) {
      _cancelNest();
      _moveHold.cancel();
      return;
    }

    // A confirmed folder stays while the pointer is anywhere on that
    // tile, so a small wobble doesn't undo it.
    if (_nestConfirmed && _nestHold.key == target.id) return;

    final zone = _zoneAt(local, index);
    if (zone == _CellZone.middle) {
      _moveHold.cancel();
      _holdForFolder(target.id, local);
      return;
    }

    _cancelNest();
    // Above or below a tile is for passing through. Across the divider a
    // tile and an episode only merge, they don't move next to each other.
    if (zone == _CellZone.aboveOrBelow ||
        target.kind != _order[draggedIdx].kind) {
      _moveHold.cancel();
      return;
    }
    _moveHold.restOn((
      targetId: target.id,
      after: zone == _CellZone.rightEdge,
    ), local);
  }

  /// Which part of the cell at [index] the pointer at [local] is over. The
  /// art fills the cell above its label, and how tall it is depends on
  /// whether the title takes one line or two. So the bands above and below
  /// are as deep as the side bands are wide, measured from the cell's top
  /// (the top of the art) and from its bottom (in the label): all of the
  /// art below the top band takes a folder.
  _CellZone _zoneAt(Offset local, int index) {
    final cell = _cellOffset(index);
    final x = (local.dx - cell.dx) / _cellWidth;
    if (x < _middleStart) return _CellZone.leftEdge;
    if (x > 1 - _middleStart) return _CellZone.rightEdge;
    final band = _middleStart * _cellWidth;
    final fromTop = local.dy - cell.dy;
    final fromBottom = cell.dy + _cellHeight - local.dy;
    if (fromTop < band || fromBottom < band) return _CellZone.aboveOrBelow;
    return _CellZone.middle;
  }

  /// The pointer is on the middle of [targetId], highlighted as a nest
  /// candidate until [_nestHold] confirms it. A folder confirmed on another
  /// tile doesn't carry over, even when one drag update jumps straight
  /// from that tile's middle to this one's.
  void _holdForFolder(String targetId, Offset local) {
    final newTarget = _nestHold.key != targetId;
    _nestHold.restOn(targetId, local);
    if (newTarget) setState(() => _nestConfirmed = false);
  }

  void _confirmNest() {
    final targetId = _nestHold.key;
    final targetTitle =
        _order.where((t) => t.id == targetId).firstOrNull?.title ?? '?';
    Log.info(
      _tag,
      'Nest CONFIRMED',
      data: {
        'draggedId': _draggedId ?? '',
        'targetId': targetId ?? '',
        'targetTitle': targetTitle,
      },
    );
    setState(() => _nestConfirmed = true);
    unawaited(HapticFeedback.mediumImpact());
  }

  void _cancelNest() {
    final hadTarget = _nestHold.key != null || _nestConfirmed;
    final target = _nestHold.key;
    _nestHold.cancel();
    if (!hadTarget) return;
    Log.debug(
      _tag,
      'Nest cancelled',
      data: {'target': target ?? 'none', 'wasConfirmed': '$_nestConfirmed'},
    );
    setState(() => _nestConfirmed = false);
  }

  /// Empty space below the last row of the dragged item's block counts as
  /// resting after that block's last item. The blocks are the tiles and
  /// the episodes, so a tile never moves into the episode lane via this
  /// path, and the other way round.
  void _holdForBlockEnd(Offset local) {
    final draggedIdx = _draggedIndex;
    if (draggedIdx < 0) return;
    final endOfBlock =
        _order[draggedIdx].kind == GridItemKind.tile
            ? _boundary - 1
            : _order.length - 1;
    // An empty slot in the last row, or already last: nothing to move.
    final pastLastRow =
        endOfBlock >= 0 && local.dy >= _cellOffset(endOfBlock).dy + _cellHeight;
    if (draggedIdx == endOfBlock || !pastLastRow) {
      _moveHold.cancel();
      return;
    }
    _moveHold.restOn((targetId: _order[endOfBlock].id, after: true), local);
  }

  /// Moves the dragged item where the pointer rests, also when it is
  /// released there before [_moveDelay] is up.
  void _applyPendingMove() {
    final move = _moveHold.key;
    _moveHold.cancel();
    final draggedIdx = _draggedIndex;
    if (move == null || draggedIdx < 0) return;

    final dragged = _order.removeAt(draggedIdx);
    final targetIdx = _order.indexWhere((t) => t.id == move.targetId);
    final target = _order[targetIdx];
    final insertAt = move.after ? targetIdx + 1 : targetIdx;
    _order.insert(insertAt, dragged);
    if (insertAt == draggedIdx) return; // already there

    _orderChanged = true;
    unawaited(HapticFeedback.selectionClick());
    Log.debug(
      _tag,
      'MOVE',
      data: {
        'from': '$draggedIdx',
        'to': '$insertAt',
        'side': move.after ? 'after' : 'before',
        'target': target.title,
      },
    );
    setState(() {});
  }

  void _onDragEnd() {
    if (_draggedId == null) {
      Log.warn(_tag, 'Drag END but no drag active');
      return;
    }

    final draggedId = _draggedId!;
    _applyPendingMove();
    final nestTarget = _nestConfirmed ? _nestHold.key : null;

    Log.info(
      _tag,
      'Drag END',
      data: {
        'draggedId': draggedId,
        'nestTarget': nestTarget ?? 'none',
        'orderChanged': '$_orderChanged',
        'updates': '$_dragUpdateCount',
      },
    );

    var committed = true;
    if (_activeDropZone != null && _activeDropZone! < widget.dropZones.length) {
      final zone = widget.dropZones[_activeDropZone!];
      Log.info(
        _tag,
        'DROP ZONE action',
        data: {'tileId': draggedId, 'zone': zone.label},
      );
      zone.onDrop(draggedId);
    } else if (nestTarget != null) {
      Log.info(
        _tag,
        'NESTING',
        data: {'childId': draggedId, 'parentId': nestTarget},
      );
      widget.onNest(draggedId, nestTarget);
    } else if (_orderChanged) {
      Log.info(
        _tag,
        'REORDER committed',
        data: {'order': _order.map((t) => t.title).join(', ')},
      );
      widget.onReorder(_order.map((t) => t.id).toList());
    } else {
      committed = false;
      Log.debug(_tag, 'Drop (no change)');
    }

    _droppedId = draggedId;
    setState(() {
      _draggedId = null;
      _activeDropZone = null;
      // A committing drag triggers a parent rebuild (via the callback ->
      // repo -> provider) that resyncs _order. A no-op drag doesn't, so
      // pull in any widget.items change that arrived mid-drag —
      // didUpdateWidget skips the resync while a drag is active.
      if (!committed) {
        _order = List.of(widget.items);
        _recomputeBoundary();
      }
    });
    _cancelNest();

    Future.delayed(const Duration(milliseconds: 200), () {
      if (mounted && _droppedId == draggedId) {
        setState(() => _droppedId = null);
      }
    });
  }

  // ── Build ─────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // The grid contents: a Stack of positioned tiles inside a SizedBox
    // whose height is calculated from the number of rows. Width is
    // discovered from the parent's [BoxConstraints.maxWidth].
    final grid = LayoutBuilder(
      builder: (context, constraints) {
        _columns = parentGridColumns(constraints.maxWidth);
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

    // Takes all available height from a bounded parent; the internal scroll
    // view handles overflow when there are more rows than fit on screen.
    return Column(
      children: [
        Expanded(child: SingleChildScrollView(child: grid)),
        if (showDropZones) _buildDropZonesPadding(context),
      ],
    );
  }

  Widget _buildDropZonesPadding(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).padding.bottom),
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
    final isNestTarget = item.id == _nestHold.key && _nestConfirmed;
    final isNestCandidate = item.id == _nestHold.key && !_nestConfirmed;
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
            // One drag at a time. A second finger on another tile would
            // otherwise start a drag whose end also ends the first one.
            maxSimultaneousDrags:
                _draggedId == null || _draggedId == item.id ? 1 : 0,
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
            childWhenDragging: Opacity(opacity: 0.3, child: _tileContent(item)),
            onDragStarted: () => _onDragStart(item.id),
            onDragUpdate: _onDragUpdate,
            // Fires for every drop, accepted or not, while the tile is
            // mounted, and it stays mounted for the whole drag since _order
            // keeps every item. onDraggableCanceled would fire as well, as
            // no DragTarget takes these drops, and end the drag twice.
            onDragEnd: (_) => _onDragEnd(),
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
      height: dropZoneHeight,
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

  // A Timer marks when the press has outlived the tap window, rather than
  // measuring elapsed DateTime.now() at pointer-up. DateTime.now() doesn't
  // advance under the widget-test fake clock, so a held press there read
  // as a tap; a Timer fires on tester.pump(Duration) like real time.
  // (The grid's _Hold uses a Timer for the same reason.)
  Timer? _tapWindow;
  bool _windowExpired = false;

  void _reset() {
    _tapWindow?.cancel();
    _tapWindow = null;
    _downPos = null;
    _windowExpired = false;
  }

  @override
  void dispose() {
    _tapWindow?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (e) {
        _downPos = e.localPosition;
        _windowExpired = false;
        _tapWindow?.cancel();
        _tapWindow = Timer(_longPressDelay, () => _windowExpired = true);
      },
      onPointerUp: (e) {
        if (_downPos == null) return;
        final dist = (e.localPosition - _downPos!).distance;
        final expired = _windowExpired;
        _reset();
        // Quick tap: released within the long-press window and moved
        // less than 20px.
        if (!expired && dist < 20) widget.onTap();
      },
      onPointerCancel: (_) => _reset(),
      child: widget.child,
    );
  }
}
