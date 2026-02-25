/// ARD Playback: NowPlayingBar visibility and controls.
///
/// Tests: start playback → NowPlayingBar appears → pause from bar works.
library;

import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/database/tile_item_repository.dart';
import 'package:lauschi/features/player/player_provider.dart';
import 'package:lauschi/features/player/widgets/now_playing_bar.dart';
import 'package:patrol/patrol.dart';

import 'ard_helpers.dart';
import 'helpers.dart';

void main() {
  patrolTest(
    'NowPlayingBar appears and controls work',
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

      // ── NowPlayingBar should appear ────────────────────────────────────
      // Pump extra frames for AnimatedSwitcher to complete.
      await pumpFrames($);

      expect(
        find.byType(NowPlayingBar),
        findsOneWidget,
        reason: 'NowPlayingBar should appear when audio is playing',
      );

      // Bar should show the track title.
      expect(
        find.text(episode.episodeTitle),
        findsWidgets,
        reason: 'NowPlayingBar should show episode title',
      );

      // ── Pause from NowPlayingBar ───────────────────────────────────────
      // The bar has a small pause button (tooltip: 'Pause').
      await $(find.descendant(
        of: find.byType(NowPlayingBar),
        matching: find.byIcon(Icons.pause_rounded),
      ))
          .tap();
      await waitForPause($);

      expect(container.read(playerProvider).isPlaying, isFalse);

      // ── Resume from NowPlayingBar ──────────────────────────────────────
      await $(find.descendant(
        of: find.byType(NowPlayingBar),
        matching: find.byIcon(Icons.play_arrow_rounded),
      ))
          .tap();
      await waitForPlayback($);

      expect(container.read(playerProvider).isPlaying, isTrue);

      await stopPlayback($);
    },
  );
}
