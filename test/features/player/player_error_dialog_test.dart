import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/features/player/player_error.dart';
import 'package:lauschi/features/player/player_provider.dart';
import 'package:lauschi/features/player/player_state.dart';
import 'package:lauschi/features/player/screens/player/screen.dart';
import 'package:lauschi/features/player/widgets/player_error_dialog.dart';

import '../../helpers/fake_player_notifier.dart';

void main() {
  group('showPlayerErrorDialog', () {
    setUp(resetPlayerErrorDialogGuard);

    testWidgets(
      'dialog button works after the screen that showed it was popped',
      (tester) async {
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

        // The push Future never completes until pop, so unawaited().
        unawaited(
          tester
              .state<NavigatorState>(find.byType(Navigator))
              .pushNamed('/player'),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('Test Track'), findsOneWidget);

        // Close the player, then raise the error while the pop
        // transition is still running. This is the sequence from the
        // field: the screen's ref.listen shows the dialog while the
        // screen is still mounted (mid-transition), then the transition
        // finishes and unmounts the screen, while the dialog lives on
        // the root navigator.
        await tester.tap(find.byKey(const Key('player_close_button')));
        await tester.pump();
        fakeNotifier.setError(PlayerError.spotifyPlaybackFailed);
        await tester.pump(); // ref.listen fires
        await tester.pump(); // post-frame callback shows the dialog
        expect(find.text(ErrorCategory.oops.headline), findsOneWidget);

        // Finish the pop transition: player screen unmounts, dialog
        // stays up. Two timed pumps: the first establishes the ticker
        // baseline, the second drives the transition to completion; the
        // trailing zero-duration pumps let the navigator dispose the
        // finished route.
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump();
        expect(find.text('Test Track'), findsNothing);
        expect(find.text(ErrorCategory.oops.headline), findsOneWidget);

        // Tapping the action button must dismiss the dialog and clear
        // the error, not throw a dead-ref StateError. The dialog is not
        // barrier-dismissible, so a throwing button traps the user.
        await tester.tap(find.text(ErrorCategory.oops.actionLabel));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        expect(tester.takeException(), isNull);
        expect(find.text(ErrorCategory.oops.headline), findsNothing);
        expect(fakeNotifier.clearErrorCalled, isTrue);
        expect(find.text('Home'), findsOneWidget);
      },
    );

    testWidgets('one error shows one dialog even with multiple listening '
        'screens', (tester) async {
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
            home: const _ListeningHost(),
            routes: {'/player': (_) => const PlayerScreen()},
          ),
        ),
      );

      unawaited(
        tester
            .state<NavigatorState>(find.byType(Navigator))
            .pushNamed('/player'),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Test Track'), findsOneWidget);

      // Both the host below and the player screen listen for errors.
      // Without deduplication each would push its own dialog.
      fakeNotifier.setError(PlayerError.spotifyPlaybackFailed);
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(find.byType(Dialog), findsOneWidget);

      // The surviving dialog must be dismissible.
      await tester.tap(find.text(ErrorCategory.oops.actionLabel));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(tester.takeException(), isNull);
      expect(find.byType(Dialog), findsNothing);
      expect(fakeNotifier.clearErrorCalled, isTrue);
    });

    testWidgets('dialog closes even when clearing the error throws', (
      tester,
    ) async {
      final fakeNotifier = _ThrowingClearErrorNotifier(
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

      unawaited(
        tester
            .state<NavigatorState>(find.byType(Navigator))
            .pushNamed('/player'),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Test Track'), findsOneWidget);

      fakeNotifier.setError(PlayerError.spotifyPlaybackFailed);
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(find.byType(Dialog), findsOneWidget);

      // The button pops before clearing the error, so even a throwing
      // notifier must not leave the (non-barrier-dismissible) dialog
      // stuck on screen.
      await tester.tap(find.text(ErrorCategory.oops.actionLabel));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();

      final exception = tester.takeException();
      expect(exception, isA<StateError>());
      expect(
        (exception as StateError).message,
        'simulated clearError failure',
      );
      expect(find.byType(Dialog), findsNothing);
    });
  });
}

/// Mimics the error-listening pattern of the kid home and tile detail
/// screens, so tests can have a second listener below the player.
class _ListeningHost extends ConsumerWidget {
  const _ListeningHost();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen(playerProvider.select((s) => s.error), (prev, next) {
      if (next != null && next != prev) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (context.mounted) {
            unawaited(showPlayerErrorDialog(context, error: next));
          }
        });
      }
    });
    return const Scaffold(body: Text('Home'));
  }
}

class _ThrowingClearErrorNotifier extends FakePlayerNotifier {
  _ThrowingClearErrorNotifier(super.initialState);

  @override
  void clearError() {
    throw StateError('simulated clearError failure');
  }
}
