import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/features/tiles/widgets/audio_tile.dart';
import 'package:lauschi/features/tiles/widgets/tile_card.dart';

/// A tap whose press animation gets interrupted by the next touch must
/// still fire its callback. Awaiting the reverse animation before the
/// callback swallows the tap when a second tap-down cancels the ticker:
/// the kid taps twice and nothing plays.
void main() {
  Future<void> tapThenInterrupt(WidgetTester tester, Finder target) async {
    final center = tester.getCenter(target);

    // Full press: recognizer deadline (100ms) + forward animation
    // (150ms) both complete, so the reverse after up runs its full
    // 150ms window.
    final first = await tester.startGesture(center);
    await tester.pump(const Duration(milliseconds: 300));
    await first.up();

    // Second touch lands immediately; its tap-down fires at the 100ms
    // recognizer deadline, inside the 150ms reverse window, canceling
    // the reverse ticker. The gesture then ends as a cancel (drag).
    final second = await tester.startGesture(center);
    await tester.pump(const Duration(milliseconds: 120));
    await second.cancel();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets(
    'TileItem fires onTap when the reverse animation is interrupted',
    (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 200,
                height: 200,
                child: TileItem(
                  title: 'Folge 7',
                  kidMode: true,
                  onTap: () => taps++,
                ),
              ),
            ),
          ),
        ),
      );

      await tapThenInterrupt(tester, find.byType(TileItem));

      expect(taps, 1, reason: 'the completed first tap must not be swallowed');
    },
  );

  testWidgets('TileCard fires onTap when the card is disposed mid-reverse', (
    tester,
  ) async {
    // A DB stream update can remove or regroup a card right after a
    // tap; the queued callback must already have fired by then.
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 200,
              height: 200,
              child: TileCard(
                title: 'TKKG',
                episodeCount: 12,
                onTap: () => taps++,
              ),
            ),
          ),
        ),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(TileCard)),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await gesture.up();

    // Replace the tree while the 150ms reverse animation would still
    // be running; disposing the controller cancels its ticker.
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump(const Duration(milliseconds: 400));

    expect(taps, 1, reason: 'the tap completed before the card vanished');
  });
}
