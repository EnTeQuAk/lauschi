import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/router/app_router.dart';
import 'package:lauschi/features/player/player_error.dart';
import 'package:lauschi/features/player/player_state.dart';

import '../../helpers/fake_player_notifier.dart';
import '../../helpers/player_error_harness.dart';

void main() {
  group('PlayerErrorHost', () {
    testWidgets('a player error shows exactly one dialog', (tester) async {
      final notifier = FakePlayerNotifier(const PlaybackState(isReady: true));
      final container = errorHostContainer(notifier);
      addTearDown(container.dispose);

      await pumpErrorHostApp(tester, container);
      await raisePlayerError(
        tester,
        notifier,
        PlayerError.spotifyPlaybackFailed,
      );

      expect(find.byType(Dialog), findsOneWidget);
      expect(find.text(ErrorCategory.oops.headline), findsOneWidget);
    });

    testWidgets('a newer error replaces the dialog content in place', (
      tester,
    ) async {
      // Only one dialog shows at a time, so when a different error
      // arrives while a dialog is open it must take over the visible
      // dialog: otherwise the parent reads a stale cause, and
      // dismissing clears the real one unseen.
      final notifier = FakePlayerNotifier(const PlaybackState(isReady: true));
      final container = errorHostContainer(notifier);
      addTearDown(container.dispose);

      await pumpErrorHostApp(tester, container);
      await raisePlayerError(
        tester,
        notifier,
        PlayerError.spotifyPlaybackFailed,
      );
      expect(
        find.text(PlayerError.spotifyPlaybackFailed.message),
        findsOneWidget,
        reason: 'precondition: dialog shows the first error',
      );

      notifier.setError(PlayerError.spotifyAuthExpired);
      await tester.pump();

      expect(find.byType(Dialog), findsOneWidget);
      expect(find.text(PlayerError.spotifyAuthExpired.message), findsOneWidget);
      expect(
        find.text(PlayerError.spotifyPlaybackFailed.message),
        findsNothing,
      );
      expect(
        find.text(ErrorCategory.parentAction.subtitle),
        findsOneWidget,
        reason: 'category presentation follows the newer error too',
      );
    });

    testWidgets('"Nochmal probieren" closes the dialog and retries the card', (
      tester,
    ) async {
      final notifier = FakePlayerNotifier(const PlaybackState(isReady: true));
      final container = errorHostContainer(notifier);
      addTearDown(container.dispose);

      await pumpErrorHostApp(tester, container);
      await raisePlayerError(
        tester,
        notifier,
        PlayerError.spotifyPlaybackFailed,
      );
      expect(find.byType(Dialog), findsOneWidget);

      await tester.tap(find.text(ErrorCategory.oops.actionLabel));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(tester.takeException(), isNull);
      expect(find.byType(Dialog), findsNothing);
      expect(notifier.retryCalled, isTrue);
    });

    testWidgets('dismissing the dialog leaves the player screen', (
      tester,
    ) async {
      // The player screen's content is gone for good; keeping the kid on
      // a dead player screen helps nobody, so the dismissal pops it.
      final notifier = FakePlayerNotifier(playingState);
      final container = errorHostContainer(notifier);
      addTearDown(container.dispose);

      await pumpErrorHostApp(tester, container);

      unawaited(container.read(appRouterProvider).push(AppRoutes.player));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const Key('player_close_button')), findsOneWidget);

      await raisePlayerError(tester, notifier, PlayerError.contentUnavailable);
      expect(find.byType(Dialog), findsOneWidget);

      await tester.tap(find.text(ErrorCategory.gone.actionLabel));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));

      expect(tester.takeException(), isNull);
      expect(find.byType(Dialog), findsNothing);
      expect(
        find.byKey(const Key('player_close_button')),
        findsNothing,
        reason: 'the dead player screen was popped after the dialog',
      );
      expect(find.text('Meine Hörspiele'), findsOneWidget);
    });

    testWidgets('a retry keeps the player screen open', (tester) async {
      // "Nochmal probieren" plays the card again, so the kid stays on
      // the player and sees it load.
      final notifier = FakePlayerNotifier(playingState);
      final container = errorHostContainer(notifier);
      addTearDown(container.dispose);

      await pumpErrorHostApp(tester, container);

      unawaited(container.read(appRouterProvider).push(AppRoutes.player));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      await raisePlayerError(tester, notifier, PlayerError.playbackFailed);
      await tester.tap(find.text(ErrorCategory.oops.actionLabel));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));

      expect(tester.takeException(), isNull);
      expect(find.byType(Dialog), findsNothing);
      expect(notifier.retryCalled, isTrue);
      expect(find.byKey(const Key('player_close_button')), findsOneWidget);
    });

    testWidgets('a system back pop still clears the error', (tester) async {
      // The dialog is not barrier-dismissible, but Android back can pop
      // it without a result; stale error state would suppress the next
      // identical error's dialog.
      final notifier = FakePlayerNotifier(const PlaybackState(isReady: true));
      final container = errorHostContainer(notifier);
      addTearDown(container.dispose);

      await pumpErrorHostApp(tester, container);
      await raisePlayerError(
        tester,
        notifier,
        PlayerError.spotifyPlaybackFailed,
      );
      expect(find.byType(Dialog), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byType(Dialog), findsNothing);
      expect(notifier.clearErrorCalled, isTrue);
    });

    testWidgets('dialog closes even when its action throws', (tester) async {
      // A throwing retry must not trap the kid behind a modal that is
      // not barrier-dismissible.
      final notifier = _ThrowingNotifier(const PlaybackState(isReady: true));
      final container = errorHostContainer(notifier);
      addTearDown(container.dispose);

      await pumpErrorHostApp(tester, container);
      await raisePlayerError(
        tester,
        notifier,
        PlayerError.spotifyPlaybackFailed,
      );
      expect(find.byType(Dialog), findsOneWidget);

      await tester.tap(find.text(ErrorCategory.oops.actionLabel));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // The throw surfaces as a test exception; swallow it here, the
      // point is that the dialog is gone regardless.
      tester.takeException();
      expect(find.byType(Dialog), findsNothing);
    });
  });
}

class _ThrowingNotifier extends FakePlayerNotifier {
  _ThrowingNotifier(super.initialState);

  @override
  void clearError() {
    throw StateError('simulated clearError failure');
  }

  @override
  Future<void> retry() => throw StateError('simulated retry failure');
}
