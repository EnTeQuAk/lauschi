/// ARD Playback: Mark episode as heard on completion.
///
/// Tests the 5s-from-end completion threshold: seeking to 6s remaining
/// should NOT mark heard, but reaching 3s remaining should.
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
    'does NOT mark heard when paused outside completion threshold',
    ($) async {
      await pumpApp($, prefs: {'onboarding_complete': true});

      final container = getContainer($);
      final episode = await getStableTestEpisode(container);
      final itemId = await insertTestEpisode($, episode);

      final notifier = container.read(playerProvider.notifier);
      final items = container.read(tileItemRepositoryProvider);

      unawaited(notifier.playCard(itemId));
      await waitForPlayback($);

      // Wait for duration to be known.
      var attempts = 0;
      while (container.read(playerProvider).durationMs == 0 && attempts < 50) {
        await $.pump(const Duration(milliseconds: 100));
        attempts++;
      }

      final duration = container.read(playerProvider).durationMs;
      expect(duration, greaterThan(10000));

      // Seek to 8s from end — outside the 5s completion threshold.
      await notifier.seek(duration - 8000);
      await $.pump(const Duration(seconds: 1));

      // Pause here — should NOT trigger completion.
      await notifier.pause();
      await waitForPause($);
      await $.pump(const Duration(seconds: 1));

      final item = await items.getById(itemId);
      expect(
        item!.isHeard,
        isFalse,
        reason:
            'Should NOT be marked heard when paused 8s from end '
            '(threshold is 5s)',
      );

      await stopPlayback($);
    },
  );

  patrolTest(
    'marks episode heard when playback reaches end',
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

      unawaited(notifier.playCard(itemId));
      await waitForPlayback($);

      // Wait for duration.
      var attempts = 0;
      while (container.read(playerProvider).durationMs == 0 && attempts < 50) {
        await $.pump(const Duration(milliseconds: 100));
        attempts++;
      }

      final duration = container.read(playerProvider).durationMs;
      expect(duration, greaterThan(10000));

      // Seek to 3s from end — inside the 5s completion threshold.
      await notifier.seek(duration - 3000);
      await pumpFrames($);

      // Let it play to completion (3s remaining + detection delay).
      for (var i = 0; i < 50; i++) {
        await $.pump(const Duration(milliseconds: 200));
        if (!container.read(playerProvider).isPlaying) break;
      }

      await $.pump(const Duration(seconds: 2));

      item = await items.getById(itemId);
      expect(
        item!.isHeard,
        isTrue,
        reason: 'Episode should be marked heard after reaching end',
      );

      await stopPlayback($);
    },
  );
}
