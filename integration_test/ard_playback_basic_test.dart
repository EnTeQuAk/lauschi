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
import 'package:lauschi/features/player/screens/player/screen.dart';
import 'package:patrol/patrol.dart';

import 'ard_helpers.dart';
import 'helpers.dart';

void main() {
  patrolTest(
    'plays ARD episode and controls playback',
    ($) async {
      // ── Setup: app + ungrouped ARD episode ─────────────────────────────
      await pumpApp($, prefs: {'onboarding_complete': true});
      await clearAppState($);

      final container = getContainer($);
      final episode = await getStableTestEpisode(container);
      final itemId = await insertTestEpisode($, episode);

      // ── Start playback via provider ────────────────────────────────────
      final notifier = container.read(playerProvider.notifier);
      unawaited(notifier.playCard(itemId));

      await waitForPlayback($);
      // (waitForPlayback fails fast on errors, so by this point
      // we know error == null and isPlaying == true.)

      final playingState = container.read(playerProvider);
      expect(playingState.isPlaying, isTrue);
      expect(playingState.activeCardId, itemId);

      // Track URI matches the inserted episode. Without this, a
      // future bug that loaded a stale track but set the right
      // activeCardId would silently pass. Caught during round-1
      // test infra review (Group G G3 follow-on).
      expect(
        playingState.track?.uri,
        episode.providerUri,
        reason:
            'Player must be playing the inserted ARD episode, '
            'not a stale leftover with the right activeCardId',
      );

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
      await pumpFrames($);
      await waitForPause($);

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
