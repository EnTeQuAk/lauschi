/// Regression test for LAUSCHI-1H: media notification crash when playing
/// a single episode (no next track).
///
/// The compact notification requested action index [0, 1, 2] but only
/// 2 controls existed (prev + play/pause) when hasNextTrack was false.
/// This crashed on Android 9 (Galaxy Note 8) with RemoteServiceException:
/// "setShowActionsInCompactView: action 2 out of bounds (max 1)".
///
/// Modern Android ignores the out-of-bounds index, so this test only
/// verifies the playback-with-no-next-track path works. The actual crash
/// requires Android <= 9 to reproduce.
library;

import 'dart:async' show unawaited;

import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/features/player/player_provider.dart';
import 'package:patrol/patrol.dart';

import 'ard_helpers.dart';
import 'helpers.dart';

void main() {
  patrolTest(
    'single episode plays without notification crash (LAUSCHI-1H)',
    ($) async {
      await pumpApp($, prefs: {'onboarding_complete': true});

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
    },
  );
}
