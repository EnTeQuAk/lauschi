import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/features/player/player_error.dart';
import 'package:lauschi/features/player/player_provider.dart';
import 'package:lauschi/features/player/player_state.dart';
import 'package:lauschi/features/player/screens/player/screen.dart';

import '../../helpers/fake_player_notifier.dart';

void main() {
  group('PlayerErrorDialog', () {
    testWidgets('shows "gone" dialog for expired content', (tester) async {
      final fakeNotifier = FakePlayerNotifier(
        const PlaybackState(
          isReady: true,
          track: TrackInfo(
            uri: 'test:uri',
            name: 'Test Track',
            artist: 'Test',
            album: 'Test Album',
          ),
        ),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [playerProvider.overrideWith(() => fakeNotifier)],
          child: const MaterialApp(home: PlayerScreen()),
        ),
      );
      await tester.pump();

      // Context-assert: PlayerScreen actually rendered with the
      // test track. Without this, a future regression where the
      // screen fails to build (e.g. a missing required provider)
      // would still let the dialog assertions run on an empty
      // screen and fail with a confusing 'expected 1 widget,
      // found 0' instead of pointing at the actual problem.
      expect(find.text('Test Track'), findsOneWidget);

      // Trigger the error after build so ref.listen fires.
      fakeNotifier.setError(PlayerError.contentUnavailable);
      await tester.pump(); // ref.listen fires
      await tester.pump(); // post-frame callback
      await tester.pump(); // dialog animation

      expect(find.text(ErrorCategory.gone.headline), findsOneWidget);
      expect(find.textContaining(ErrorCategory.gone.subtitle), findsOneWidget);
      expect(find.text(ErrorCategory.gone.actionLabel), findsOneWidget);
      // Technical message for parents
      expect(find.text(PlayerError.contentUnavailable.message), findsOneWidget);
    });

    testWidgets('shows "oops" dialog for connection errors', (tester) async {
      final fakeNotifier = FakePlayerNotifier(
        const PlaybackState(
          isReady: true,
          track: TrackInfo(
            uri: 'test:uri',
            name: 'Test Track',
            artist: 'Test',
            album: 'Test Album',
          ),
        ),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [playerProvider.overrideWith(() => fakeNotifier)],
          child: const MaterialApp(home: PlayerScreen()),
        ),
      );
      await tester.pump();

      // Context-assert: see comment in the "gone" test above.
      expect(find.text('Test Track'), findsOneWidget);

      fakeNotifier.setError(PlayerError.spotifyConnectionLost);
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(find.text(ErrorCategory.oops.headline), findsOneWidget);
      expect(find.text(ErrorCategory.oops.actionLabel), findsOneWidget);
      expect(
        find.text(PlayerError.spotifyConnectionLost.message),
        findsOneWidget,
      );
    });

    testWidgets('shows "parentAction" dialog for auth errors', (
      tester,
    ) async {
      final fakeNotifier = FakePlayerNotifier(
        const PlaybackState(
          isReady: true,
          track: TrackInfo(
            uri: 'test:uri',
            name: 'Test Track',
            artist: 'Test',
            album: 'Test Album',
          ),
        ),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [playerProvider.overrideWith(() => fakeNotifier)],
          child: const MaterialApp(home: PlayerScreen()),
        ),
      );
      await tester.pump();

      // Context-assert: see comment in the "gone" test above.
      expect(find.text('Test Track'), findsOneWidget);

      fakeNotifier.setError(PlayerError.spotifyAuthExpired);
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(
        find.text(ErrorCategory.parentAction.headline),
        findsOneWidget,
      );
      expect(
        find.text(PlayerError.spotifyAuthExpired.message),
        findsOneWidget,
      );
    });

    testWidgets('dismiss clears error and pops player', (tester) async {
      final fakeNotifier = FakePlayerNotifier(
        const PlaybackState(
          isReady: true,
          track: TrackInfo(
            uri: 'test:uri',
            name: 'Test Track',
            artist: 'Test',
            album: 'Test Album',
          ),
        ),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [playerProvider.overrideWith(() => fakeNotifier)],
          child: MaterialApp(
            home: const Scaffold(body: Text('Home')),
            routes: {'/player': (_) => const PlayerScreen()},
          ),
        ),
      );

      // Navigate to player. The push Future never completes
      // until pop, so we have to use unawaited().
      unawaited(
        tester
            .state<NavigatorState>(find.byType(Navigator))
            .pushNamed('/player'),
      );
      await tester.pump();
      await tester.pump();

      // Context-assert: PlayerScreen is actually visible after
      // the navigation pumps. Without this, a navigation that
      // silently failed would let the test trigger an error on
      // the wrong screen and the dismiss check would still pass
      // (clearError is called either way) — but the assertion
      // about popping the player would be testing the wrong
      // navigator state.
      expect(find.text('Test Track'), findsOneWidget);

      // Trigger error.
      fakeNotifier.setError(PlayerError.spotifyConnectionLost);
      await tester.pump();
      await tester.pump();
      await tester.pump();

      // Tap the action button.
      await tester.tap(find.text(ErrorCategory.oops.actionLabel));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(fakeNotifier.clearErrorCalled, isTrue);
    });

    testWidgets('no dialog when there is no error', (tester) async {
      final fakeNotifier = FakePlayerNotifier(
        const PlaybackState(
          isReady: true,
          isPlaying: true,
          durationMs: 60000,
          positionMs: 5000,
          track: TrackInfo(
            uri: 'test:uri',
            name: 'Test Track',
            artist: 'Test',
            album: 'Test Album',
          ),
        ),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [playerProvider.overrideWith(() => fakeNotifier)],
          child: const MaterialApp(home: PlayerScreen()),
        ),
      );
      await tester.pump();
      await tester.pump();

      // Normal player visible, no dialog.
      expect(find.text('Test Track'), findsOneWidget);
      expect(find.text(ErrorCategory.oops.headline), findsNothing);
      expect(find.text(ErrorCategory.gone.headline), findsNothing);
      expect(find.text(ErrorCategory.parentAction.headline), findsNothing);
    });
  });
}
