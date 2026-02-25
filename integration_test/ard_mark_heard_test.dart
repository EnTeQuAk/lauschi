/// ARD Playback: Mark episode as heard on completion.
///
/// Tests: play → seek to near-end → let it complete → verify isHeard in DB.
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
    'marks episode heard when playback completes',
    ($) async {
      await pumpApp($, prefs: {'onboarding_complete': true});

      final container = getContainer($);
      final episode = await getStableTestEpisode(container);
      final itemId = await insertTestEpisode($, episode);

      final notifier = container.read(playerProvider.notifier);
      final items = container.read(tileItemRepositoryProvider);

      // Verify starts as unheard.
      var item = await items.getById(itemId);
      expect(item!.isHeard, isFalse);

      // ── Play and seek to near the end ──────────────────────────────────
      unawaited(notifier.playCard(itemId));
      await waitForPlayback($);

      // Wait for duration to be known.
      var attempts = 0;
      while (container.read(playerProvider).durationMs == 0 && attempts < 50) {
        await $.pump(const Duration(milliseconds: 100));
        attempts++;
      }

      final duration = container.read(playerProvider).durationMs;
      expect(duration, greaterThan(10000), reason: 'Need >10s audio');

      // Seek to 3s from the end — within the completion threshold (5s).
      await notifier.seek(duration - 3000);
      await pumpFrames($);

      // ── Let it play to completion ──────────────────────────────────────
      // Wait up to 10s for the episode to finish.
      for (var i = 0; i < 50; i++) {
        await $.pump(const Duration(milliseconds: 200));
        final state = container.read(playerProvider);
        if (!state.isPlaying) break;
      }

      // ── Verify marked heard in database ────────────────────────────────
      // Give the completion handler time to write to DB.
      await $.pump(const Duration(seconds: 2));

      item = await items.getById(itemId);
      expect(
        item!.isHeard,
        isTrue,
        reason: 'Episode should be marked heard after completion',
      );

      await stopPlayback($);
    },
  );
}
