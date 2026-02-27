/// ARD Playback: Position saving and resume.
///
/// Tests the 20s minimum play-time threshold and position accuracy.
/// Verifies that:
/// - Brief taps don't save position (threshold not met)
/// - state.positionMs tracks actual playback (not stale)
/// - Saved position in DB is close to actual playback time
/// - Position saves happen periodically while playing (not just on pause)
/// - Resume restores the saved position
///
/// This is intentionally slow (~55s total of real playback).
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
    'does NOT save position before 20s threshold',
    ($) async {
      await pumpApp($, prefs: {'onboarding_complete': true});

      final container = getContainer($);
      final episode = await getStableTestEpisode(container);
      final itemId = await insertTestEpisode($, episode);

      final notifier = container.read(playerProvider.notifier);
      final items = container.read(tileItemRepositoryProvider);

      // ── Play for 15 seconds (under the 20s threshold) ──────────────────
      unawaited(notifier.playCard(itemId));
      await waitForPlayback($);
      await $.pump(const Duration(seconds: 15));

      // ── Pause — should NOT save because threshold not met ──────────────
      await notifier.pause();
      await waitForPause($);
      await $.pump(const Duration(seconds: 1));

      final item = await items.getById(itemId);
      expect(
        item!.lastPositionMs,
        equals(0),
        reason:
            'Position should NOT be saved before 20s threshold '
            '(got ${item.lastPositionMs}ms after 15s play)',
      );

      await stopPlayback($);
    },
  );

  patrolTest(
    'state.positionMs tracks actual playback progress',
    ($) async {
      await pumpApp($, prefs: {'onboarding_complete': true});

      final container = getContainer($);
      final episode = await getStableTestEpisode(container);
      final itemId = await insertTestEpisode($, episode);

      final notifier = container.read(playerProvider.notifier);

      unawaited(notifier.playCard(itemId));
      await waitForPlayback($);

      // After 5s, state.positionMs should reflect ~5s of playback.
      // This catches the stale-position bug where DirectPlayer updated
      // _positionMs internally but never emitted to provider state.
      await $.pump(const Duration(seconds: 5));
      final pos5s = currentPositionMs($);
      expect(
        pos5s,
        greaterThan(3000),
        reason:
            'state.positionMs should be ~5s after 5s of play '
            '(got ${pos5s}ms — stale position bug if near 0)',
      );

      // After 10s total, position should have advanced further.
      await $.pump(const Duration(seconds: 5));
      final pos10s = currentPositionMs($);
      expect(
        pos10s,
        greaterThan(pos5s + 2000),
        reason:
            'Position should advance between checks '
            '(5s=$pos5s, 10s=$pos10s)',
      );

      await stopPlayback($);
    },
  );

  patrolTest(
    'position saves to DB periodically while playing',
    ($) async {
      await pumpApp($, prefs: {'onboarding_complete': true});

      final container = getContainer($);
      final episode = await getStableTestEpisode(container);
      final itemId = await insertTestEpisode($, episode);

      final notifier = container.read(playerProvider.notifier);
      final items = container.read(tileItemRepositoryProvider);

      unawaited(notifier.playCard(itemId));
      await waitForPlayback($);

      // Play past threshold + one timer tick (20s + 10s = 30s).
      // The timer fires every 10s; first save happens at the tick
      // after the 20s threshold is met.
      await $.pump(const Duration(seconds: 32));

      // Position should be saved WITHOUT pausing. This catches the
      // timer-restart bug where _startPositionSave() was called on
      // every state event, cancelling the timer before it could tick.
      final item = await items.getById(itemId);
      expect(
        item!.lastPositionMs,
        greaterThan(20000),
        reason:
            'Position should be saved by periodic timer while playing '
            '(got ${item.lastPositionMs}ms — timer-restart bug if 0)',
      );

      // Saved position should be close to actual playback time.
      // With 1/sec position emissions and 10s save interval, max
      // staleness is ~1s. Allow 5s tolerance for test timing jitter.
      final statePos = currentPositionMs($);
      final savedPos = item.lastPositionMs;
      final drift = (statePos - savedPos).abs();
      expect(
        drift,
        lessThan(12000),
        reason:
            'Saved position should be close to actual playback '
            '(state=${statePos}ms, saved=${savedPos}ms, drift=${drift}ms)',
      );

      await stopPlayback($);
    },
  );

  patrolTest(
    'saves position on pause and resumes correctly',
    ($) async {
      await pumpApp($, prefs: {'onboarding_complete': true});

      final container = getContainer($);
      final episode = await getStableTestEpisode(container);
      final itemId = await insertTestEpisode($, episode);

      final notifier = container.read(playerProvider.notifier);
      final items = container.read(tileItemRepositoryProvider);

      // ── Play for 25 seconds (past the 20s threshold) ───────────────────
      unawaited(notifier.playCard(itemId));
      await waitForPlayback($);

      expect(
        currentPositionMs($),
        lessThan(3000),
        reason: 'Fresh play should start near 0',
      );

      await $.pump(const Duration(seconds: 25));

      // ── Pause — should trigger position save ───────────────────────────
      await notifier.pause();
      await waitForPause($);
      await $.pump(const Duration(seconds: 1));

      final savedItem = await items.getById(itemId);
      expect(
        savedItem!.lastPositionMs,
        greaterThan(20000),
        reason:
            'Position should be saved on pause after 25s play '
            '(got ${savedItem.lastPositionMs}ms)',
      );

      // Saved position should be close to where we actually were.
      // Not just "greater than threshold" but actually near 25s.
      expect(
        savedItem.lastPositionMs,
        lessThan(35000),
        reason:
            'Saved position should be near 25s, not wildly off '
            '(got ${savedItem.lastPositionMs}ms)',
      );

      // ── Play again — should resume from saved position ─────────────────
      unawaited(notifier.playCard(itemId));
      await waitForPlayback($);
      await $.pump(const Duration(seconds: 3));

      final resumePosition = currentPositionMs($);
      expect(
        resumePosition,
        greaterThan(18000),
        reason:
            'Should resume near saved position '
            '(saved=${savedItem.lastPositionMs}, got=$resumePosition)',
      );

      await stopPlayback($);
    },
  );
}
