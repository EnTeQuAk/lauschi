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

      // ── Navigate to player screen via NowPlayingBar ────────────────────
      await $(find.byKey(const ValueKey('now-playing'))).tap();
      // Extra frames for the page push animation to complete.
      await pumpFrames($, count: 20);
      expect(find.byType(PlayerScreen), findsOneWidget);

      // ── Pause via the large pause icon on player screen ────────────────
      // The play/pause button renders Icons.pause_rounded when playing,
      // Icons.play_arrow_rounded when paused.
      await $(find.byIcon(Icons.pause_rounded)).first.tap();
      await waitForPause($);

      final pausedPosition = currentPositionMs($);
      expect(pausedPosition, greaterThan(0));

      // ── Resume via the large play icon ─────────────────────────────────
      await $(find.byIcon(Icons.play_arrow_rounded)).first.tap();
      await waitForPlayback($);

      // Wait long enough that position clearly advances past the pause point.
      // Short waits can fail due to interpolation overshoot at pause time vs
      // the actual SDK position reported after resume.
      await $.pump(const Duration(seconds: 5));
      expect(currentPositionMs($), greaterThan(pausedPosition));

      // ── Cleanup ────────────────────────────────────────────────────────
      await stopPlayback($);
    },
  );
}
