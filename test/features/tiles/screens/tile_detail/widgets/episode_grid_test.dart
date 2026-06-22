import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/database/app_database.dart' as db;
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/tiles/screens/tile_detail/widgets/episode_grid.dart';

db.TileItem _episode({
  required String id,
  bool isHeard = false,
  int lastPositionMs = 0,
  int sortOrder = 0,
  int? episodeNumber,
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
  );
}

/// Wraps EpisodeGrid in a constrained box to force a scrollable layout.
/// 400x400 with 2 columns means ~4 rows visible; we need more episodes
/// to push the target below the fold.
class _Harness extends StatefulWidget {
  const _Harness({
    required this.episodes,
    required this.initialNextUnheardId,
  });

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
            onCardTap: (_) {},
            albumProgress: (_) => 0,
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
    final harnessState = tester.state<_HarnessState>(find.byType(_Harness));
    harnessState.setState(() {
      harnessState.nextUnheardId = 'ep-28';
    });
    // First pump: rebuild + post-frame callback registers animateTo.
    // Second pump: animation ticker starts.
    // Third pump: advance past the 300ms animation duration.
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(controller.offset, greaterThan(initialOffset));
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
    final controller = scrollable.controller!;
    final initialOffset = controller.offset;

    // Manually scroll to 0 to see if rebuild re-scrolls.
    controller.jumpTo(0);
    await tester.pump();

    // Rebuild with the same nextUnheardId.
    final harnessState = tester.state<_HarnessState>(find.byType(_Harness));
    harnessState.setState(() {});
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
    final harnessState = tester.state<_HarnessState>(find.byType(_Harness));
    harnessState.setState(() {
      harnessState.nextUnheardId = 'ep-4';
    });
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

  testWidgets('breathing glow animates continuously', (tester) async {
    // ep-2 is on row 1, fully visible in the 400px viewport.
    await tester.pumpWidget(
      _Harness(episodes: episodes, initialNextUnheardId: 'ep-2'),
    );
    await tester.pump();
    await tester.pump();

    // Glow controller: 2000ms forward (0→1), 2000ms reverse (1→0).
    // blurRadius ranges from 10 (at 0) to 16 (at 1).
    // Advance near the peak of the forward cycle.
    await tester.pump(const Duration(milliseconds: 1900));

    BoxShadow? findGlowShadow() {
      for (final d in tester.widgetList<DecoratedBox>(
        find.byType(DecoratedBox),
      )) {
        final decoration = d.decoration;
        if (decoration is! BoxDecoration) continue;
        final shadows = decoration.boxShadow;
        if (shadows == null || shadows.isEmpty) continue;
        if (shadows.first.blurRadius >= 10) return shadows.first;
      }
      return null;
    }

    final shadow = findGlowShadow();
    expect(shadow, isNotNull, reason: 'Glow shadow should exist');
    // Near the peak (t ≈ 0.95), blur should be well above the minimum of 10.
    expect(shadow!.blurRadius, greaterThan(14));
  });
}
