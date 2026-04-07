/// ARD Playback: Rapid card switching and mashing controls.
///
/// Tests the generation counter and backend teardown by rapidly
/// switching between cards and mashing play/pause. This is the
/// primary kids-device resilience test: toddlers don't wait for
/// loading spinners.
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
    'rapid card switching lands on the last card',
    ($) async {
      await pumpApp($, prefs: {'onboarding_complete': true});
      await clearAppState($);

      final container = getContainer($);
      final episode = await getStableTestEpisode(container);

      // Insert two distinct episodes from the same show.
      final itemA = await insertTestEpisode($, episode);
      final itemB = await insertTestEpisode($, episode);

      final notifier = container.read(playerProvider.notifier);

      // ── Rapid fire: A → B → A → B without waiting ──────────────────
      unawaited(notifier.playCard(itemA));
      unawaited(notifier.playCard(itemB));
      unawaited(notifier.playCard(itemA));
      unawaited(notifier.playCard(itemB));

      // Wait for playback to settle on the last card.
      await waitForPlayback($);

      final state = container.read(playerProvider);
      expect(state.isPlaying, isTrue);
      expect(
        state.activeCardId,
        itemB,
        reason: 'Should play the last requested card, not an earlier one',
      );
      expect(
        state.error,
        isNull,
        reason: 'Rapid switching should not produce errors',
      );
      expect(
        state.positionMs,
        lessThan(5000),
        reason: 'Fresh play should start near beginning',
      );

      await stopPlayback($);
    },
  );

  patrolTest(
    'double-tap same card is idempotent',
    ($) async {
      await pumpApp($, prefs: {'onboarding_complete': true});
      await clearAppState($);

      final container = getContainer($);
      final episode = await getStableTestEpisode(container);
      final itemId = await insertTestEpisode($, episode);

      final notifier = container.read(playerProvider.notifier);

      // ── Tap the same card twice rapidly ─────────────────────────────
      unawaited(notifier.playCard(itemId));
      unawaited(notifier.playCard(itemId));

      await waitForPlayback($);

      final state = container.read(playerProvider);
      expect(state.isPlaying, isTrue);
      expect(state.activeCardId, itemId);
      expect(state.error, isNull, reason: 'No error from double-tap');

      await stopPlayback($);
    },
  );

  patrolTest(
    'play-pause mashing settles correctly',
    ($) async {
      await pumpApp($, prefs: {'onboarding_complete': true});
      await clearAppState($);

      final container = getContainer($);
      final episode = await getStableTestEpisode(container);
      final itemId = await insertTestEpisode($, episode);

      final notifier = container.read(playerProvider.notifier);

      // Start playback.
      unawaited(notifier.playCard(itemId));
      await waitForPlayback($);

      // ── Mash pause/resume rapidly ──────────────────────────────────
      unawaited(notifier.pause());
      unawaited(notifier.resume());
      unawaited(notifier.pause());
      unawaited(notifier.resume());
      unawaited(notifier.pause());

      // Give it a moment to settle.
      await $.pump(const Duration(seconds: 1));

      // Last command was pause, so we should be paused.
      await waitForPause($);
      final state = container.read(playerProvider);
      expect(state.isPlaying, isFalse);
      expect(state.activeCardId, itemId);
      expect(state.error, isNull, reason: 'No errors from rapid toggling');

      await stopPlayback($);
    },
  );

  patrolTest(
    'switching cards during playback preserves position of first card',
    ($) async {
      await pumpApp($, prefs: {'onboarding_complete': true});
      await clearAppState($);

      final container = getContainer($);
      final episode = await getStableTestEpisode(container);
      final itemA = await insertTestEpisode($, episode);
      final itemB = await insertTestEpisode($, episode);

      final notifier = container.read(playerProvider.notifier);
      final items = container.read(tileItemRepositoryProvider);

      // ── Play card A for 25+ seconds (past min save threshold) ──────
      unawaited(notifier.playCard(itemA));
      await waitForPlayback($);

      // Wait past the 20-second minimum play time for position saving.
      await $.pump(const Duration(seconds: 25));

      final posBeforeSwitch = container.read(playerProvider).positionMs;
      expect(
        posBeforeSwitch,
        greaterThan(20000),
        reason: 'Should have played for 20+ seconds',
      );

      // ── Switch to card B ───────────────────────────────────────────
      unawaited(notifier.playCard(itemB));
      await waitForPlayback($);

      expect(
        container.read(playerProvider).activeCardId,
        itemB,
        reason: 'Now playing card B',
      );

      // ── Verify card A position was saved ───────────────────────────
      await waitForCondition(
        $,
        () async {
          final saved = await items.getById(itemA);
          return saved != null && saved.lastPositionMs > 15000;
        },
        description: 'Card A position saved (was at ${posBeforeSwitch}ms)',
      );

      await stopPlayback($);
    },
  );
}
