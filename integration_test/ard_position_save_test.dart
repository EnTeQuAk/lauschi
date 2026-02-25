/// ARD Playback: Position saving and resume.
///
/// The position save has a 30s minimum play-time threshold to prevent
/// brief taps from marking episodes as "in progress". This test must
/// actually play audio for 30+ seconds.
///
/// This is intentionally a slow test (~35s of playback).
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
    'saves position after 30s play threshold',
    ($) async {
      await pumpApp($, prefs: {'onboarding_complete': true});

      final container = getContainer($);
      final episode = await getStableTestEpisode(container);
      final itemId = await insertTestEpisode($, episode);

      final notifier = container.read(playerProvider.notifier);
      final items = container.read(tileItemRepositoryProvider);

      // ── Play for 32+ seconds (past the 30s threshold) ──────────────────
      unawaited(notifier.playCard(itemId));
      await waitForPlayback($);

      // Let it play for 32 seconds.
      await $.pump(const Duration(seconds: 32));

      // ── Pause — should trigger position save ───────────────────────────
      await notifier.pause();
      await waitForPause($);

      final pausedPosition = currentPositionMs($);
      expect(pausedPosition, greaterThan(25000), reason: 'Should be past 25s');

      // Give the save timer callback a moment.
      await $.pump(const Duration(seconds: 1));

      // ── Verify position was saved to database ──────────────────────────
      final savedItem = await items.getById(itemId);
      expect(savedItem, isNotNull);
      expect(
        savedItem!.lastPositionMs,
        greaterThan(20000),
        reason: 'Position should be saved (~${pausedPosition}ms)',
      );

      // ── Play again — should resume from saved position ─────────────────
      unawaited(notifier.playCard(itemId));
      await waitForPlayback($);

      // Give it time to seek to the resume point.
      await $.pump(const Duration(seconds: 3));

      final resumePosition = currentPositionMs($);
      expect(
        resumePosition,
        greaterThan(20000),
        reason: 'Should resume near saved position',
      );

      await stopPlayback($);
    },
  );
}
