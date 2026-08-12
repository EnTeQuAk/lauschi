import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/features/player/player_provider.dart';
import 'package:lauschi/features/player/player_state.dart';
import 'package:lauschi/features/player/screens/player/widgets/interpolated_progress.dart';
import 'package:lauschi/features/player/screens/player/widgets/player_progress_bar.dart';

import '../../helpers/fake_player_notifier.dart';

const _durationMs = 100000;

// Paused so the AnimationController doesn't drift between pumps; the
// pending-seek suppression logic under test is independent of play
// state.
const _initial = PlaybackState(
  isReady: true,
  durationMs: _durationMs,
  positionMs: 10000,
  track: TrackInfo(uri: 'ard:item:1', name: 'Folge 7'),
);

int _renderedPositionMs(WidgetTester tester) =>
    tester.widget<PlayerProgressBar>(find.byType(PlayerProgressBar)).positionMs;

/// ref.listen fires on change, not on mount, so the widget's duration
/// sync only runs after a state update. Prime it with one.
Future<void> _primeSync(
  WidgetTester tester,
  FakePlayerNotifier notifier,
) async {
  notifier.emit(_initial.copyWith(positionMs: 10000));
  await tester.pump();
}

void main() {
  testWidgets('a never-confirmed seek stops freezing the progress bar', (
    tester,
  ) async {
    final notifier = FakePlayerNotifier(_initial);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [playerProvider.overrideWith(() => notifier)],
        child: MaterialApp(
          home: Scaffold(
            body: InterpolatedProgress(onSeek: (_) {}),
          ),
        ),
      ),
    );
    await tester.pump();
    await _primeSync(tester, notifier);

    // Seek to the middle. Normally the backend confirms near 50000 and
    // the suppression lifts; here the seek fails and playback resumes
    // elsewhere, so 50000 is never reported.
    tester
        .widget<PlayerProgressBar>(find.byType(PlayerProgressBar))
        .onSeek(50000);
    await tester.pump();
    expect(
      _renderedPositionMs(tester),
      closeTo(50000, 500),
      reason: 'the bar sits at the seek target while confirmation pends',
    );

    // The backend keeps reporting a far-off position (the resumed spot).
    // Each is suppressed while the pending seek is unresolved.
    notifier.emit(_initial.copyWith(positionMs: 8000));
    await tester.pump();
    expect(
      _renderedPositionMs(tester),
      closeTo(50000, 500),
      reason: 'stale/wrong positions are suppressed during the pending seek',
    );

    // After the timeout the suppression must give up and re-sync the
    // bar to where playback actually is, instead of freezing at 50000
    // for the rest of the episode.
    await tester.pump(const Duration(seconds: 4));
    expect(
      _renderedPositionMs(tester),
      closeTo(8000, 500),
      reason: 'the bar re-syncs to the real position after the timeout',
    );
  });

  testWidgets('a confirmed seek lifts suppression immediately', (tester) async {
    final notifier = FakePlayerNotifier(_initial);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [playerProvider.overrideWith(() => notifier)],
        child: MaterialApp(
          home: Scaffold(body: InterpolatedProgress(onSeek: (_) {})),
        ),
      ),
    );
    await tester.pump();
    await _primeSync(tester, notifier);

    tester
        .widget<PlayerProgressBar>(find.byType(PlayerProgressBar))
        .onSeek(50000);
    await tester.pump();

    // Backend confirms near the target: suppression lifts, and later
    // real updates are accepted normally.
    notifier.emit(_initial.copyWith(positionMs: 50200));
    await tester.pump();
    notifier.emit(_initial.copyWith(positionMs: 60000));
    await tester.pump();

    expect(
      _renderedPositionMs(tester),
      closeTo(60000, 500),
      reason: 'after a confirmed seek, normal position snaps resume',
    );
  });
}
