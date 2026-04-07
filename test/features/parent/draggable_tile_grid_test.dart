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
                  onLongPress: (_) {},
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

    testWidgets('shrinkWrap=true reproduces the bug when set to false', (
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
                  onLongPress: (_) {},
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
            onLongPress: (_) {},
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
                  onLongPress: (_) {},
                ),
              ),
            ],
          ),
        ),
      );

      expect(tester.takeException(), isNull);
    });
  });
}
