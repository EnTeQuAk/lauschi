/// Tests playback of a single-episode tile (no next track).
///
/// History: this file was originally a regression test for LAUSCHI-1H,
/// a media notification crash on Android 9 (Galaxy Note 8). The compact
/// notification requested action index [0, 1, 2] but only 2 controls
/// existed (prev + play/pause) when `hasNextTrack` was false. The
/// compact-view fix in commit 7400663c made the actions list match the
/// available control count.
///
/// **Modern Android ignores the out-of-bounds index**, so this test
/// can no longer catch the original LAUSCHI-1H crash on a current
/// device. Per the round-1 test infra review (sonnet flagged this as
/// a BLOCKER for honest naming), the test was renamed to reflect what
/// it actually verifies on contemporary Android: the playback path
/// for a tile with no sibling episodes still works end-to-end. The
/// LAUSCHI-1H tag stays in this comment for git-blame archaeology
/// but is removed from the test name to avoid implying coverage
/// that doesn't exist.
///
/// If we ever add a Galaxy Note 8 (Android 9) device to the test
/// matrix, the original assertion (notification doesn't crash on
/// playback start) becomes meaningful again — re-run this test with
/// the LAUSCHI-1H name on that device.
library;

import 'dart:async' show unawaited;

import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/features/player/player_provider.dart';
import 'package:patrol/patrol.dart';

import 'ard_helpers.dart';
import 'helpers.dart';

void main() {
  patrolTest(
    'single-episode tile (no next track) plays end-to-end',
    ($) async {
      await pumpApp($, prefs: {'onboarding_complete': true});
      await clearAppState($);

      final container = getContainer($);
      final episode = await getStableTestEpisode(container);

      // Single episode in its own tile: no siblings = no next track.
      final result = await insertTestTileWithEpisode($, episode);

      final notifier = container.read(playerProvider.notifier);
      unawaited(notifier.playCard(result.itemId));

      await waitForPlayback($);

      final state = container.read(playerProvider);
      expect(state.isPlaying, isTrue);
      expect(state.error, isNull);
      expect(state.activeCardId, result.itemId);
      // Track URI must match — this catches the case where playCard
      // loaded the wrong source despite reporting the right activeCardId.
      expect(
        state.track?.uri,
        episode.providerUri,
        reason: 'Player must load the inserted episode',
      );

      await stopPlayback($);
    },
  );
}
