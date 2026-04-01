/// ARD Playback: NowPlayingBar visibility, controls, and navigation.
///
/// Tests: bar appears during playback, shows track info, pause/resume work,
/// tapping bar opens full-screen player.
library;

import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/database/tile_item_repository.dart';
import 'package:lauschi/features/player/player_provider.dart';
import 'package:lauschi/features/player/screens/player/screen.dart';
import 'package:lauschi/features/player/widgets/now_playing_bar.dart';
import 'package:patrol/patrol.dart';

import 'ard_helpers.dart';
import 'helpers.dart';

void main() {
  patrolTest(
    'NowPlayingBar appears, controls work, and navigates to player',
    ($) async {
      await pumpApp($, prefs: {'onboarding_complete': true});

      final container = getContainer($);
      final episode = await getStableTestEpisode(container);
      await insertTestEpisode($, episode);

      // ── Before playback: no NowPlayingBar ──────────────────────────────
      expect(find.byType(NowPlayingBar), findsNothing);

      // ── Start playback ─────────────────────────────────────────────────
      final notifier = container.read(playerProvider.notifier);
      final items =
          await container.read(tileItemRepositoryProvider).getUngrouped();
      unawaited(notifier.playCard(items.first.id));
      await waitForPlayback($);

      // Pump for AnimatedSwitcher.
      await pumpFrames($);

      // ── Bar appears with track info ────────────────────────────────────
      expect(find.byType(NowPlayingBar), findsOneWidget);
      expect(
        find.text(episode.episodeTitle),
        findsWidgets,
        reason: 'Bar should show episode title',
      );

      // ── Pause from bar ─────────────────────────────────────────────────
      await $.tester.tap(find.byKey(const ValueKey('now_playing_toggle')));
      await pumpFrames($, count: 5);
      await waitForPause($);
      expect(container.read(playerProvider).isPlaying, isFalse);

      // ── Resume from bar ────────────────────────────────────────────────
      await $.tester.tap(find.byKey(const ValueKey('now_playing_toggle')));
      await pumpFrames($, count: 5);
      await waitForPlayback($);
      expect(container.read(playerProvider).isPlaying, isTrue);

      // ── Tap bar body to navigate to full-screen player ─────────────────
      await $(find.byKey(const ValueKey('now-playing'))).tap();
      await pumpFrames($, count: 20);
      expect(
        find.byType(PlayerScreen),
        findsOneWidget,
        reason: 'Tapping NowPlayingBar should open PlayerScreen',
      );

      await stopPlayback($);
    },
  );
}
