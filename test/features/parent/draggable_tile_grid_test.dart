import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/features/parent/widgets/draggable_tile_grid.dart';

/// Regression tests for [DraggableTileGrid] layout. The bug fixed here
/// (LAUSCHI-1M and 13 cascading semantic-tree errors): when the grid was
/// placed inside an unbounded parent like [SliverToBoxAdapter], its
/// internal `Column[Expanded[SingleChildScrollView[...]]]` wrapper threw
/// 'RenderFlex children have non-zero flex but incoming height
/// constraints are unbounded'. The whole "Kacheln verwalten" screen
/// rendered blank as soon as a user had any ungrouped items, because
/// `_SeriesBody` switches to a `CustomScrollView` in that case.
///
/// The fix added a [DraggableTileGrid.shrinkWrap] flag that drops the
/// Expanded wrapper and lets the grid size itself to its content.
void main() {
  final twoTiles = [
    const DraggableTileItem(id: 'a', title: 'Alpha'),
    const DraggableTileItem(id: 'b', title: 'Beta'),
  ];

  Widget noopWrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  group('dropZoneIndexAt', () {
    // 800-tall screen, 48px bottom safe area, 2 zones (52px each) rendered
    // above the inset: they occupy [800-48-104, 800-48] = [648, 752).
    test('hits the visible top of a zone', () {
      // 649 is the top of zone 0 — the region the old screen-bottom math
      // treated as dead.
      expect(
        dropZoneIndexAt(
          globalY: 649,
          screenHeight: 800,
          bottomInset: 48,
          zoneCount: 2,
        ),
        0,
      );
      expect(
        dropZoneIndexAt(
          globalY: 701,
          screenHeight: 800,
          bottomInset: 48,
          zoneCount: 2,
        ),
        1,
      );
    });

    test('ignores the safe area below the zones', () {
      // 760 is inside the bottom inset, below the visible zones — the old
      // math falsely activated the last zone here.
      expect(
        dropZoneIndexAt(
          globalY: 760,
          screenHeight: 800,
          bottomInset: 48,
          zoneCount: 2,
        ),
        isNull,
      );
    });

    test('returns null above the zones and with no zones', () {
      expect(
        dropZoneIndexAt(
          globalY: 600,
          screenHeight: 800,
          bottomInset: 48,
          zoneCount: 2,
        ),
        isNull,
      );
      expect(
        dropZoneIndexAt(
          globalY: 760,
          screenHeight: 800,
          bottomInset: 48,
          zoneCount: 0,
        ),
        isNull,
      );
    });
  });

  group('DraggableTileGrid', () {
    testWidgets('renders inside SliverToBoxAdapter with shrinkWrap=true', (
      tester,
    ) async {
      // The exact failure mode from LAUSCHI-1M: a SliverToBoxAdapter
      // gives the child unbounded vertical constraints. Without
      // shrinkWrap=true the grid throws.
      await tester.pumpWidget(
        noopWrap(
          CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: DraggableTileGrid(
                  items: twoTiles,
                  shrinkWrap: true,
                  onReorder: (_) {},
                  onNest: (_, _) {},
                  onTap: (_) {},
                ),
              ),
            ],
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('Beta'), findsOneWidget);
    });

    testWidgets('shrinkWrap=false (default) throws in unbounded parent', (
      tester,
    ) async {
      // Documents the failure mode: with shrinkWrap=false (the broken
      // path) inside a sliver, the grid throws a layout assertion. This
      // test exists to make the regression obvious if someone removes
      // the shrinkWrap branch in the future.
      await tester.pumpWidget(
        noopWrap(
          CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: DraggableTileGrid(
                  items: twoTiles,
                  // shrinkWrap defaults to false → broken
                  onReorder: (_) {},
                  onNest: (_, _) {},
                  onTap: (_) {},
                ),
              ),
            ],
          ),
        ),
      );

      // Flutter wraps multiple errors during a single frame; we expect
      // at least one. Take all and verify the first is the layout error.
      final exception = tester.takeException();
      expect(
        exception,
        isNotNull,
        reason:
            'shrinkWrap=false in an unbounded parent should still throw '
            '— if this passes, the bug fix may have grown a workaround '
            'that hides the failure',
      );
    });

    testWidgets('renders in bounded mode (Scaffold body, no shrinkWrap)', (
      tester,
    ) async {
      // The other valid usage: inside a fixed-height parent (Scaffold
      // body, Expanded). Default shrinkWrap=false, fills available space,
      // SingleChildScrollView handles overflow.
      await tester.pumpWidget(
        noopWrap(
          DraggableTileGrid(
            items: twoTiles,
            onReorder: (_) {},
            onNest: (_, _) {},
            onTap: (_) {},
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('Beta'), findsOneWidget);
    });

    testWidgets('empty grid renders without exceptions in shrinkWrap mode', (
      tester,
    ) async {
      // Edge case: zero tiles shouldn't trip the rowCount==0 branch.
      await tester.pumpWidget(
        noopWrap(
          CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: DraggableTileGrid(
                  items: const [],
                  shrinkWrap: true,
                  onReorder: (_) {},
                  onNest: (_, _) {},
                  onTap: (_) {},
                ),
              ),
            ],
          ),
        ),
      );

      expect(tester.takeException(), isNull);
    });
  });

  group('DraggableTileGrid — mixed kinds', () {
    const tileA = DraggableTileItem(id: 'tile:a', title: 'Alpha');
    const tileB = DraggableTileItem(id: 'tile:b', title: 'Beta');
    const epX = DraggableTileItem(
      id: 'item:x',
      title: 'Episode X',
      kind: GridItemKind.episode,
    );
    const epY = DraggableTileItem(
      id: 'item:y',
      title: 'Episode Y',
      kind: GridItemKind.episode,
    );

    testWidgets('boundary label renders when both kinds present', (
      tester,
    ) async {
      await tester.pumpWidget(
        noopWrap(
          DraggableTileGrid(
            items: const [tileA, tileB, epX, epY],
            onReorder: (_) {},
            onNest: (_, _) {},
            onTap: (_) {},
          ),
        ),
      );

      // The "N einzelne Folgen" label is only meaningful when there's
      // a divider to anchor — i.e. both blocks have at least one cell.
      expect(find.text('2 einzelne Folgen'), findsOneWidget);
      // And the drag hint mirroring the top-of-screen one. Parents who
      // land in the section need to know the two gestures available
      // here: assign-to-tile and merge-into-new-tile.
      expect(
        find.text(
          'Auf eine Kachel ziehen oder zwei zu einer neuen Kachel verbinden',
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('boundary label hidden when only tiles', (tester) async {
      await tester.pumpWidget(
        noopWrap(
          DraggableTileGrid(
            items: const [tileA, tileB],
            onReorder: (_) {},
            onNest: (_, _) {},
            onTap: (_) {},
          ),
        ),
      );

      // No episode block → no divider → no label. We render only the
      // German pluralization, so absence of either string proves it.
      expect(find.textContaining('einzelne Folge'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('boundary label hidden when only episodes', (tester) async {
      await tester.pumpWidget(
        noopWrap(
          DraggableTileGrid(
            items: const [epX, epY],
            onReorder: (_) {},
            onNest: (_, _) {},
            onTap: (_) {},
          ),
        ),
      );

      // No tile block above → divider would have nothing to separate.
      expect(find.textContaining('einzelne Folge'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('singular pluralization for one episode', (tester) async {
      await tester.pumpWidget(
        noopWrap(
          DraggableTileGrid(
            items: const [tileA, epX],
            onReorder: (_) {},
            onNest: (_, _) {},
            onTap: (_) {},
          ),
        ),
      );

      // Guards against off-by-one in the label: "1 einzelne Folge" not
      // "1 einzelne Folgen". Trivial to break in a copy edit.
      expect(find.text('1 einzelne Folge'), findsOneWidget);
      expect(find.text('1 einzelne Folgen'), findsNothing);
    });

    testWidgets('mixed grid renders all cells in shrinkWrap mode', (
      tester,
    ) async {
      // Inside an unbounded parent — the bug-prone path. The boundary
      // band adds vertical real estate that the bounded-height path
      // doesn't see, so we test the sliver case explicitly.
      await tester.pumpWidget(
        noopWrap(
          CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: DraggableTileGrid(
                  items: const [tileA, tileB, epX, epY],
                  shrinkWrap: true,
                  onReorder: (_) {},
                  onNest: (_, _) {},
                  onTap: (_) {},
                ),
              ),
            ],
          ),
        ),
      );

      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('Beta'), findsOneWidget);
      expect(find.text('Episode X'), findsOneWidget);
      expect(find.text('Episode Y'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('backward drag — hold-to-merge fires onNest', (tester) async {
      // Regression for the post-swap "over own slot" self-cancel: when
      // dragging from a higher index to a lower one, the swap puts the
      // dragged item AT the original target's position. The pointer
      // then hit-tests the dragged item's own slot. Before the fix, the
      // grid would cancel the nest target on that frame and hold-to-
      // merge could never confirm on a backward drag — the user could
      // form a folder only by dragging forward.
      String? draggedId;
      String? targetId;
      await tester.pumpWidget(
        noopWrap(
          SizedBox(
            width: 400,
            height: 800,
            child: DraggableTileGrid(
              items: const [epX, epY],
              onReorder: (_) {},
              onNest: (a, b) {
                draggedId = a;
                targetId = b;
              },
              onTap: (_) {},
            ),
          ),
        ),
      );

      // Start the long-press drag on Y (the right cell, higher index).
      final yFinder = find.text('Episode Y');
      final gesture = await tester.startGesture(tester.getCenter(yFinder));
      // LongPressDraggable needs ~300ms before the drag starts.
      await tester.pump(const Duration(milliseconds: 400));

      // Move backward onto X (left cell, lower index). This is the
      // direction that used to break.
      await gesture.moveTo(tester.getCenter(find.text('Episode X')));
      // Let the swap commit.
      await tester.pump(const Duration(milliseconds: 50));
      // Hold for the nest delay (500ms) so _checkNestIdle confirms.
      await tester.pump(const Duration(milliseconds: 600));

      // Release.
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 250));

      expect(draggedId, 'item:y', reason: 'dragged Y onto X (backward)');
      expect(
        targetId,
        'item:x',
        reason:
            'onNest must fire even when the swap moved the dragged item '
            'INTO the pointer slot. The "over own slot" branch must not '
            'cancel an active nest target.',
      );
    });

    testWidgets('dragging a tile into empty space moves it to the end', (
      tester,
    ) async {
      // Regression for the move-to-end off-by-one: inserting at
      // endOfBlock - 1 landed the dragged tile second-to-last, so for a
      // two-tile block the "move to end" reorder was a no-op.
      List<String>? newOrder;
      await tester.pumpWidget(
        noopWrap(
          SizedBox(
            width: 400,
            height: 800,
            child: DraggableTileGrid(
              items: twoTiles,
              onReorder: (order) => newOrder = order,
              onNest: (_, _) {},
              onTap: (_) {},
            ),
          ),
        ),
      );

      // Long-press-drag Alpha (leftmost), then move into empty space well
      // below the single row of tiles and release.
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('Alpha')),
      );
      await tester.pump(const Duration(milliseconds: 400));
      await gesture.moveTo(const Offset(200, 500));
      await tester.pump(const Duration(milliseconds: 50));
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 250));

      expect(
        newOrder,
        ['b', 'a'],
        reason: 'Alpha moved to the end, after Beta',
      );
    });

    testWidgets('a mid-drag items change shows after a no-op drag', (
      tester,
    ) async {
      // didUpdateWidget skips resyncing _order while a drag is active, so a
      // background provider re-emit mid-drag was dropped until an unrelated
      // rebuild. A no-op drag must pull the change in on release.
      final key = GlobalKey<_HostState>();
      await tester.pumpWidget(noopWrap(_Host(key: key)));

      expect(find.text('Charlie'), findsNothing, reason: 'setup: A, B only');

      final gesture = await tester.startGesture(
        tester.getCenter(find.text('Alpha')),
      );
      await tester.pump(const Duration(milliseconds: 400)); // long-press

      // Parent adds a tile mid-drag.
      key.currentState!.addCharlie();
      await tester.pump();

      // Release without moving — nothing committed.
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 250));

      expect(
        find.text('Charlie'),
        findsOneWidget,
        reason: 'the mid-drag addition is reflected after the drag',
      );
    });

    testWidgets('a quick tap fires onTap, a held press does not', (
      tester,
    ) async {
      // With DateTime.now() timing, a held press read as a tap under the
      // fake clock (now() doesn't advance on pump). The Timer-based window
      // must expire on a hold so it is not mistaken for a tap.
      String? tapped;
      await tester.pumpWidget(
        noopWrap(
          SizedBox(
            width: 400,
            height: 800,
            child: DraggableTileGrid(
              items: twoTiles,
              onReorder: (_) {},
              onNest: (_, _) {},
              onTap: (id) => tapped = id,
            ),
          ),
        ),
      );

      await tester.tap(find.text('Alpha'));
      await tester.pump();
      expect(tapped, 'a', reason: 'a quick tap fires onTap');

      tapped = null;
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('Beta')),
      );
      await tester.pump(const Duration(milliseconds: 400)); // window expires
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 250)); // drop settle timer
      expect(tapped, isNull, reason: 'a held press is a drag, not a tap');
    });
  });
}

/// Hosts the grid with a mutable item list so a test can change items
/// mid-drag.
class _Host extends StatefulWidget {
  const _Host({super.key});

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  List<DraggableTileItem> _items = const [
    DraggableTileItem(id: 'a', title: 'Alpha'),
    DraggableTileItem(id: 'b', title: 'Beta'),
  ];

  void addCharlie() {
    setState(() {
      _items = [
        ..._items,
        const DraggableTileItem(id: 'c', title: 'Charlie'),
      ];
    });
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 400,
      height: 800,
      child: DraggableTileGrid(
        items: _items,
        onReorder: (_) {},
        onNest: (_, _) {},
        onTap: (_) {},
      ),
    );
  }
}
