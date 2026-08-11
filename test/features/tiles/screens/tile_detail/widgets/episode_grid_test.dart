import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/database/app_database.dart' as db;
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/tiles/screens/tile_detail/widgets/episode_grid.dart';

db.TileItem _episode({
  required String id,
  bool isHeard = false,
  int lastPositionMs = 0,
  int? sortOrder,
  int? episodeNumber,
  DateTime? markedUnavailable,
}) {
  return db.TileItem(
    id: id,
    title: 'Episode $id',
    cardType: 'album',
    provider: 'ard',
    providerUri: 'ard:$id',
    isHeard: isHeard,
    sortOrder: sortOrder,
    createdAt: DateTime(2026),
    totalTracks: 1,
    durationMs: 600000,
    lastTrackNumber: 0,
    lastPositionMs: lastPositionMs,
    episodeNumber: episodeNumber,
    markedUnavailable: markedUnavailable,
  );
}

void _ignore() {}
void _ignoreCard(db.TileItem _) {}

/// Wraps EpisodeGrid in a constrained box to force a scrollable layout.
/// 400x400 with 2 columns means ~4 rows visible; we need more episodes
/// to push the target below the fold.
class _Harness extends StatefulWidget {
  const _Harness({
    required this.episodes,
    required this.initialNextUnheardId,
    this.onCardTap = _ignoreCard,
    this.onExpiredTap = _ignore,
  });

  final void Function(db.TileItem) onCardTap;
  final VoidCallback onExpiredTap;
  final List<db.TileItem> episodes;
  final String? initialNextUnheardId;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  late String? nextUnheardId;

  @override
  void initState() {
    super.initState();
    nextUnheardId = widget.initialNextUnheardId;
  }

  void updateNextUnheardId(String? id) {
    setState(() {
      nextUnheardId = id;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: 400,
          child: EpisodeGrid(
            episodes: widget.episodes,
            nextUnheardId: nextUnheardId,
            activeUri: null,
            isPlaying: false,
            isActive: false,
            onCardTap: widget.onCardTap,
            onExpiredTap: widget.onExpiredTap,
          ),
        ),
      ),
    );
  }
}

void main() {
  final episodes = List.generate(
    30,
    (i) => _episode(id: 'ep-$i', sortOrder: i, episodeNumber: i + 1),
  );

  testWidgets('initial build scrolls to nextUnheardId episode', (
    tester,
  ) async {
    // Episode 20 is well below the fold in a 400px-tall viewport with 2 columns.
    await tester.pumpWidget(
      _Harness(episodes: episodes, initialNextUnheardId: 'ep-20'),
    );
    await tester.pump();
    await tester.pump();

    final scrollable = tester.widget<GridView>(find.byType(GridView));
    final controller = scrollable.controller!;
    expect(controller.offset, greaterThan(0));
  });

  testWidgets('scrolls again when nextUnheardId changes', (tester) async {
    await tester.pumpWidget(
      _Harness(episodes: episodes, initialNextUnheardId: 'ep-20'),
    );
    await tester.pump();
    await tester.pump();

    final scrollable = tester.widget<GridView>(find.byType(GridView));
    final controller = scrollable.controller!;
    final initialOffset = controller.offset;
    expect(initialOffset, greaterThan(0));

    // Simulate the badge moving to a later episode.
    tester
        .state<_HarnessState>(find.byType(_Harness))
        .updateNextUnheardId('ep-28');
    // First pump: rebuild + post-frame callback registers animateTo.
    // Second pump: animation ticker starts.
    // Third pump: advance past the 300ms animation duration.
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(controller.offset, greaterThan(initialOffset));
  });

  testWidgets('scrolls back up when the badge wraps to the top', (
    tester,
  ) async {
    // Finishing the last unheard episode wraps the badge to the first
    // unheard one near the top; the grid must follow, otherwise the
    // kid stares at a screen of heard episodes while the pulse plays
    // off-screen above.
    await tester.pumpWidget(
      _Harness(episodes: episodes, initialNextUnheardId: 'ep-28'),
    );
    await tester.pump();
    await tester.pump();

    final scrollable = tester.widget<GridView>(find.byType(GridView));
    final controller = scrollable.controller!;
    final downOffset = controller.offset;
    expect(downOffset, greaterThan(0), reason: 'precondition: scrolled down');

    tester
        .state<_HarnessState>(find.byType(_Harness))
        .updateNextUnheardId('ep-1');
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(controller.offset, 0, reason: 'grid follows the badge to the top');
  });

  testWidgets('does not yank the grid while the kid is dragging', (
    tester,
  ) async {
    await tester.pumpWidget(
      _Harness(episodes: episodes, initialNextUnheardId: 'ep-20'),
    );
    await tester.pump();
    await tester.pump();

    final scrollable = tester.widget<GridView>(find.byType(GridView));
    final controller = scrollable.controller!;

    // Kid browses: finger down, dragging, still touching.
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(GridView)),
    );
    await gesture.moveBy(const Offset(0, -50));
    await tester.pump();
    final draggedOffset = controller.offset;

    // Background playback finishes an episode; the badge advances.
    tester
        .state<_HarnessState>(find.byType(_Harness))
        .updateNextUnheardId('ep-28');
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(
      controller.offset,
      draggedOffset,
      reason: 'auto-scroll must not replace an active drag',
    );
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 600));
  });

  testWidgets('does not scroll when badge stays on same episode', (
    tester,
  ) async {
    await tester.pumpWidget(
      _Harness(episodes: episodes, initialNextUnheardId: 'ep-20'),
    );
    await tester.pump();
    await tester.pump();

    final scrollable = tester.widget<GridView>(find.byType(GridView));
    final controller =
        scrollable.controller!
          // Manually scroll to 0 to see if rebuild re-scrolls.
          ..jumpTo(0);
    await tester.pump();

    // Rebuild with the same nextUnheardId (triggers setState without changing the value).
    tester
        .state<_HarnessState>(find.byType(_Harness))
        .updateNextUnheardId('ep-20');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    // Should NOT have scrolled back, since the ID didn't change.
    expect(controller.offset, equals(0));
  });

  testWidgets('pulse animation fires when badge moves, not on initial build', (
    tester,
  ) async {
    // Use early episodes that are visible without scrolling.
    await tester.pumpWidget(
      _Harness(episodes: episodes, initialNextUnheardId: 'ep-2'),
    );
    await tester.pump();
    await tester.pump();

    // On initial build, scale should be 1.0 (no pulse).
    var transforms = tester.widgetList<Transform>(find.byType(Transform));
    expect(
      transforms.where((t) => t.transform.entry(0, 0) > 1.001),
      isEmpty,
      reason: 'Pulse should not fire on initial build',
    );

    // Move the badge to trigger a pulse.
    tester
        .state<_HarnessState>(find.byType(_Harness))
        .updateNextUnheardId('ep-4');
    // Rebuild + post-frame callback + animation start.
    await tester.pump();
    // Advance to the pulse midpoint (200ms of 400ms).
    // sin(0.5 * pi) = 1.0, so scale peaks at 1.05.
    await tester.pump(const Duration(milliseconds: 200));

    transforms = tester.widgetList<Transform>(find.byType(Transform));
    expect(
      transforms.where((t) => t.transform.entry(0, 0) > 1.01),
      isNotEmpty,
      reason: 'Pulse should scale up the Weiter episode',
    );

    // After the pulse completes (400ms total), scale returns to 1.0.
    await tester.pump(const Duration(milliseconds: 250));
    transforms = tester.widgetList<Transform>(find.byType(Transform));
    expect(
      transforms.where((t) => t.transform.entry(0, 0) > 1.001),
      isEmpty,
      reason: 'Pulse should return to normal scale',
    );
  });

  testWidgets('an expired episode routes taps to onExpiredTap', (
    tester,
  ) async {
    // This wiring shipped broken once (all tap handlers null on expired
    // cards) and later came back without coverage: a kid tapping a
    // greyed episode must get the friendly modal, never playCard on a
    // dead stream, and never silence.
    final tapped = <String>[];
    var expiredTaps = 0;
    await tester.pumpWidget(
      _Harness(
        episodes: [
          _episode(id: 'ok', episodeNumber: 1),
          _episode(
            id: 'gone',
            episodeNumber: 2,
            markedUnavailable: DateTime(2026),
          ),
        ],
        initialNextUnheardId: null,
        onCardTap: (card) => tapped.add(card.id),
        onExpiredTap: () => expiredTaps++,
      ),
    );
    await tester.pump();

    expect(
      find.bySemanticsLabel(RegExp('nicht mehr verfügbar')),
      findsOneWidget,
      reason: 'expired rendering must be announced as unavailable',
    );

    await tester.tap(find.bySemanticsLabel(RegExp('nicht mehr verfügbar')));
    await tester.pump();
    expect(expiredTaps, 1);
    expect(tapped, isEmpty, reason: 'expired tap must not reach onCardTap');

    await tester.tap(find.bySemanticsLabel(RegExp('Episode ok')));
    await tester.pump();
    expect(tapped, ['ok'], reason: 'normal episodes keep playing normally');
    expect(expiredTaps, 1);
  });

  testWidgets('Weiter badge pill is shown on nextUnheardId episode', (
    tester,
  ) async {
    await tester.pumpWidget(
      _Harness(episodes: episodes, initialNextUnheardId: 'ep-2'),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('▶ Weiter'), findsOneWidget);
  });

  testWidgets('Weiter badge disappears when nextUnheardId becomes null', (
    tester,
  ) async {
    await tester.pumpWidget(
      _Harness(episodes: episodes, initialNextUnheardId: 'ep-2'),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('▶ Weiter'), findsOneWidget);

    tester
        .state<_HarnessState>(find.byType(_Harness))
        .updateNextUnheardId(null);
    await tester.pump();

    expect(find.text('▶ Weiter'), findsNothing);
  });
}
