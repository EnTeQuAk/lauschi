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
      await clearAppState($);

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
      await waitForCondition(
        $,
        () async => container.read(playerProvider).durationMs > 0,
        description: 'Duration to be populated',
        timeout: const Duration(seconds: 15),
      );

      final duration = container.read(playerProvider).durationMs;

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

      // ── Verify position jumped to roughly 50% ─────────────────────────
      final newPosition = container.read(playerProvider).positionMs;
      final target = duration ~/ 2;

      // Slider drag isn't pixel-perfect, but should land past 30%.
      expect(
        newPosition,
        greaterThan((duration * 0.3).round()),
        reason:
            'Seek to 50% should land past 30% '
            '(got $newPosition, target=$target, duration=$duration)',
      );
      // And not overshoot past 80%.
      expect(
        newPosition,
        lessThan((duration * 0.8).round()),
        reason:
            'Seek to 50% should not overshoot past 80% '
            '(got $newPosition)',
      );

      await stopPlayback($);
    },
  );
}
