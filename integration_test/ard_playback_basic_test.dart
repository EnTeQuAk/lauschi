/// ARD Playback: Basic play/pause/resume flow.
///
/// Tests: insert episode → play via provider → verify controls work.
///
/// ARD tests call playCard directly rather than tapping tiles, because the
/// kid home screen gates taps on Spotify bridge readiness.
library;

import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/features/player/player_provider.dart';
import 'package:lauschi/features/player/screens/player_screen.dart';
import 'package:patrol/patrol.dart';

import 'ard_helpers.dart';
import 'helpers.dart';

void main() {
  patrolTest(
    'plays ARD episode and controls playback',
    ($) async {
      // ── Setup: app + ungrouped ARD episode ─────────────────────────────
      await pumpApp($, prefs: {'onboarding_complete': true});

      final container = getContainer($);
      final episode = await getStableTestEpisode(container);
      final itemId = await insertTestEpisode($, episode);

      // ── Start playback via provider ────────────────────────────────────
      final notifier = container.read(playerProvider.notifier);
      unawaited(notifier.playCard(itemId));

      await waitForPlayback($);

      final playingState = container.read(playerProvider);
      expect(playingState.isPlaying, isTrue);
      expect(playingState.activeCardId, itemId);

      // Verify fresh play starts near the beginning.
      expect(
        playingState.positionMs,
        lessThan(5000),
        reason: 'Fresh play should start near 0, not resume from stale state',
      );

      // Verify duration was populated from the audio source.
      expect(
        playingState.durationMs,
        greaterThan(0),
        reason: 'Duration should be known after playback starts',
      );

      // ── Navigate to player screen via NowPlayingBar ────────────────────
      await $(find.byKey(const ValueKey('now-playing'))).tap();
      // Extra frames for the page push animation to complete.
      await pumpFrames($, count: 30);
      expect(find.byType(PlayerScreen), findsOneWidget);

      // ── Pause via the play/pause button on player screen ──────────────
      await $.tester.tap(find.byKey(const ValueKey('play_pause_button')));
      await pumpFrames($, count: 10);
      await waitForPause($, timeout: const Duration(seconds: 10));

      final pausedPosition = currentPositionMs($);
      expect(pausedPosition, greaterThan(0));

      // ── Resume via the play/pause button ───────────────────────────────
      await $.tester.tap(find.byKey(const ValueKey('play_pause_button')));
      await pumpFrames($, count: 5);
      await waitForPlayback($);

      // Wait long enough that position clearly advances past the pause point.
      await $.pump(const Duration(seconds: 5));
      expect(currentPositionMs($), greaterThan(pausedPosition));

      // ── Cleanup ────────────────────────────────────────────────────────
      await stopPlayback($);
    },
  );
}
