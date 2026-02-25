/// ARD Playback: Seek via progress bar.
///
/// Tests: play → drag slider to ~50% → position changes.
library;

import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/features/player/player_provider.dart';
import 'package:patrol/patrol.dart';

import 'ard_helpers.dart';
import 'helpers.dart';

void main() {
  patrolTest(
    'seek slider changes playback position',
    ($) async {
      await pumpApp($, prefs: {'onboarding_complete': true});

      final container = getContainer($);
      final episode = await getStableTestEpisode(container);
      final itemId = await insertTestEpisode($, episode);

      // Start playback and navigate to player screen.
      final notifier = container.read(playerProvider.notifier);
      unawaited(notifier.playCard(itemId));
      await waitForPlayback($);

      await $(find.byKey(const ValueKey('now-playing'))).tap();
      await pumpFrames($);

      // Wait for duration to be known.
      var attempts = 0;
      while (container.read(playerProvider).durationMs == 0 && attempts < 50) {
        await $.pump(const Duration(milliseconds: 100));
        attempts++;
      }

      final duration = container.read(playerProvider).durationMs;
      expect(duration, greaterThan(0), reason: 'Should know audio duration');

      // ── Seek to ~50% via the Slider widget ─────────────────────────────
      final slider = find.byType(Slider);
      expect(slider, findsOneWidget);

      final rect = $.tester.getRect(slider);
      final startX = rect.left + 20; // near left edge
      final targetX = rect.left + (rect.width * 0.5);
      final centerY = rect.center.dy;

      await $.tester.dragFrom(
        Offset(startX, centerY),
        Offset(targetX - startX, 0),
      );
      await pumpFrames($);

      // ── Verify position jumped ─────────────────────────────────────────
      final newPosition = container.read(playerProvider).positionMs;
      // Should be significantly past where we were (~2-3s in).
      // Allow generous tolerance — slider drag isn't pixel-perfect.
      expect(
        newPosition,
        greaterThan(duration ~/ 5),
        reason: 'Position should jump forward after seek '
            '(got $newPosition, duration=$duration)',
      );

      await stopPlayback($);
    },
  );
}
