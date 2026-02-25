/// ARD Playback: Position saving and resume.
///
/// Tests the 30s minimum play-time threshold: brief taps should NOT
/// save position, but playing past the threshold should.
///
/// This is intentionally slow (~60s total: 25s + 35s of real playback).
library;

import 'dart:async' show unawaited;

import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/database/tile_item_repository.dart';
import 'package:lauschi/features/player/player_provider.dart';
import 'package:patrol/patrol.dart';

import 'ard_helpers.dart';
import 'helpers.dart';

void main() {
  patrolTest(
    'does NOT save position before 30s threshold',
    ($) async {
      await pumpApp($, prefs: {'onboarding_complete': true});

      final container = getContainer($);
      final episode = await getStableTestEpisode(container);
      final itemId = await insertTestEpisode($, episode);

      final notifier = container.read(playerProvider.notifier);
      final items = container.read(tileItemRepositoryProvider);

      // ── Play for 25 seconds (under the 30s threshold) ──────────────────
      unawaited(notifier.playCard(itemId));
      await waitForPlayback($);
      await $.pump(const Duration(seconds: 25));

      // ── Pause — should NOT save because threshold not met ──────────────
      await notifier.pause();
      await waitForPause($);
      await $.pump(const Duration(seconds: 1));

      final item = await items.getById(itemId);
      expect(
        item!.lastPositionMs,
        equals(0),
        reason: 'Position should NOT be saved before 30s threshold '
            '(got ${item.lastPositionMs}ms after 25s play)',
      );

      await stopPlayback($);
    },
  );

  patrolTest(
    'saves position after 30s threshold and resumes correctly',
    ($) async {
      await pumpApp($, prefs: {'onboarding_complete': true});

      final container = getContainer($);
      final episode = await getStableTestEpisode(container);
      final itemId = await insertTestEpisode($, episode);

      final notifier = container.read(playerProvider.notifier);
      final items = container.read(tileItemRepositoryProvider);

      // ── Play for 35 seconds (past the 30s threshold) ───────────────────
      unawaited(notifier.playCard(itemId));
      await waitForPlayback($);

      // Verify we start near the beginning, not resuming from stale state.
      expect(
        currentPositionMs($),
        lessThan(3000),
        reason: 'Fresh play should start near 0',
      );

      await $.pump(const Duration(seconds: 35));

      // ── Pause — should trigger position save ───────────────────────────
      await notifier.pause();
      await waitForPause($);

      final pausedPosition = currentPositionMs($);
      expect(pausedPosition, greaterThan(30000));

      // Query DB immediately — save happens synchronously on pause when
      // threshold is met, not on a timer.
      await $.pump(const Duration(seconds: 1));

      final savedItem = await items.getById(itemId);
      expect(
        savedItem!.lastPositionMs,
        greaterThan(25000),
        reason: 'Position should be saved on pause after 30s+ play',
      );

      // ── Play again — should resume from saved position ─────────────────
      unawaited(notifier.playCard(itemId));
      await waitForPlayback($);
      await $.pump(const Duration(seconds: 3));

      final resumePosition = currentPositionMs($);
      expect(
        resumePosition,
        greaterThan(25000),
        reason: 'Should resume near saved position '
            '(saved=${savedItem.lastPositionMs}, got=$resumePosition)',
      );

      await stopPlayback($);
    },
  );
}
