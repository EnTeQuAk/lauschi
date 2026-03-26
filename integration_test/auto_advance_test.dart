/// Integration test for auto-advance: when one episode finishes,
/// the next unheard episode in the same tile starts automatically.
library;

import 'dart:async' show unawaited;

import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/database/tile_item_repository.dart';
import 'package:lauschi/core/database/tile_repository.dart';
import 'package:lauschi/features/player/player_provider.dart';
import 'package:patrol/patrol.dart';

import 'ard_helpers.dart';
import 'helpers.dart';

void main() {
  patrolTest(
    'auto-advance plays next episode when current finishes',
    ($) async {
      await pumpApp($, prefs: {'onboarding_complete': true});

      final container = getContainer($);
      final episode = await getStableTestEpisode(container);
      final tiles = container.read(tileRepositoryProvider);
      final items = container.read(tileItemRepositoryProvider);
      final notifier = container.read(playerProvider.notifier);

      // Create a tile with two episodes. Both from the same ARD show
      // so auto-advance fires (requires hoerspiel content type + groupId).
      final tileId = await tiles.insert(title: episode.showTitle);

      final ep1Id = await items.insertArdEpisode(
        title: '${episode.episodeTitle} (ep1)',
        providerUri: episode.providerUri,
        audioUrl: episode.audioUrl,
        durationMs: episode.durationSeconds * 1000,
        tileId: tileId,
        episodeNumber: 1,
      );

      // Second episode: same audio URL (we just need a second card
      // to verify auto-advance. It'll play the same audio, that's fine).
      final ep2Id = await items.insertArdEpisode(
        title: '${episode.episodeTitle} (ep2)',
        providerUri: '${episode.providerUri}_ep2',
        audioUrl: episode.audioUrl,
        durationMs: episode.durationSeconds * 1000,
        tileId: tileId,
        episodeNumber: 2,
      );
      await pumpFrames($);

      // Before: both episodes unheard.
      final ep1Before = await items.getById(ep1Id);
      final ep2Before = await items.getById(ep2Id);
      expect(ep1Before!.isHeard, isFalse, reason: 'ep1 starts unheard');
      expect(ep2Before!.isHeard, isFalse, reason: 'ep2 starts unheard');

      // Play episode 1.
      unawaited(notifier.playCard(ep1Id));
      await waitForPlayback($);

      // Wait for duration to be known.
      var attempts = 0;
      while (container.read(playerProvider).durationMs == 0 && attempts < 50) {
        await $.pump(const Duration(milliseconds: 100));
        attempts++;
      }
      final duration = container.read(playerProvider).durationMs;
      expect(duration, greaterThan(0), reason: 'Duration must be known');

      // Verify we're playing ep1.
      expect(
        container.read(playerProvider).activeCardId,
        ep1Id,
        reason: 'Should be playing episode 1',
      );

      // Seek to 3s from end (inside the 5s completion threshold).
      await notifier.seek(duration - 3000);
      await pumpFrames($);

      // Let it play to completion + auto-advance delay (3s).
      // Poll for up to 15s: either ep1 finishes and ep2 starts, or timeout.
      var advancedToEp2 = false;
      for (var i = 0; i < 75; i++) {
        await $.pump(const Duration(milliseconds: 200));
        final state = container.read(playerProvider);
        if (state.activeCardId == ep2Id) {
          advancedToEp2 = true;
          break;
        }
      }

      expect(
        advancedToEp2,
        isTrue,
        reason: 'Should auto-advance to episode 2 after episode 1 finishes',
      );

      // Episode 1 should be marked heard.
      final ep1After = await items.getById(ep1Id);
      expect(
        ep1After!.isHeard,
        isTrue,
        reason: 'Episode 1 should be marked heard after completion',
      );

      // Episode 2 should still be unheard (just started).
      final ep2After = await items.getById(ep2Id);
      expect(
        ep2After!.isHeard,
        isFalse,
        reason: 'Episode 2 just started, should still be unheard',
      );

      // Clean up.
      await stopPlayback($);
    },
  );
}
