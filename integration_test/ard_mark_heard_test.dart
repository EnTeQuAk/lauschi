/// ARD Playback: when an episode counts as heard.
///
/// An episode is heard when the listen covered at least half of it and
/// then either the audio reached its end (just_audio reports it
/// explicitly) or the kid left it with at most min(10 %, 4 minutes) left,
/// skipping the closing credits. Tests that need a covered listen start
/// from a resume point at 60 %, like a kid continuing an earlier listen.
library;

import 'dart:async' show unawaited;

import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/database/listening_repository.dart';
import 'package:lauschi/core/database/tile_item_repository.dart';
import 'package:lauschi/features/player/listening_rules.dart';
import 'package:lauschi/features/player/player_provider.dart';
import 'package:patrol/patrol.dart';

import 'ard_helpers.dart';
import 'helpers.dart';

/// How much may be left of a [durationMs] long episode for it to count
/// as heard, the same formula as `isFinishedEnough`.
int _allowedLeftMs(int durationMs) {
  final share = (durationMs * finishedWithinShare).round();
  final cap = finishedWithinAtMost.inMilliseconds;
  return share < cap ? share : cap;
}

/// Store a resume point at 60 % of the episode, as if the kid had heard
/// that much before, so the next play covers more than half of it.
Future<void> _resumeAt60Percent(
  PatrolIntegrationTester $,
  String itemId,
  TestArdEpisode episode,
) async {
  final durationMs = episode.durationSeconds * 1000;
  final atMs = (durationMs * 0.6).round();
  await getContainer($)
      .read(listeningRepositoryProvider)
      .saveResumePoint(
        itemId: itemId,
        trackUri: episode.providerUri,
        trackNumber: 1,
        positionMs: atMs,
        elapsedMs: atMs,
        durationMs: durationMs,
      );
}

void main() {
  patrolTest('pausing well before the end does not mark heard', ($) async {
    await pumpApp($, prefs: {'onboarding_complete': true});
    await clearAppState($);

    final container = getContainer($);
    final episode = await getStableTestEpisode(container);
    final itemId = await insertTestEpisode($, episode);

    final notifier = container.read(playerProvider.notifier);
    final items = container.read(tileItemRepositoryProvider);
    await _resumeAt60Percent($, itemId, episode);

    unawaited(notifier.playCard(itemId));
    await waitForPlayback($);
    await waitForDurationKnown($);

    final duration = container.read(playerProvider).durationMs;
    expect(duration, greaterThan(10000));

    // Ten seconds more left than the rule allows.
    await notifier.seek(duration - _allowedLeftMs(duration) - 10000);
    await $.pump(const Duration(seconds: 1));
    await notifier.pause();
    await waitForPause($);
    await $.pump(const Duration(seconds: 1));

    final item = await items.getById(itemId);
    expect(item!.isHeard, isFalse);
    expect(container.read(playerProvider).isFinished, isFalse);

    await stopPlayback($);
  });

  patrolTest('pausing in the closing credits marks heard', ($) async {
    await pumpApp($, prefs: {'onboarding_complete': true});
    await clearAppState($);

    final container = getContainer($);
    final episode = await getStableTestEpisode(container);
    final itemId = await insertTestEpisode($, episode);

    final notifier = container.read(playerProvider.notifier);
    final items = container.read(tileItemRepositoryProvider);
    await _resumeAt60Percent($, itemId, episode);

    unawaited(notifier.playCard(itemId));
    await waitForPlayback($);
    await waitForDurationKnown($);

    final duration = container.read(playerProvider).durationMs;
    // Half of what the rule allows is left: the kid stops in the credits.
    await notifier.seek(duration - _allowedLeftMs(duration) ~/ 2);
    await $.pump(const Duration(seconds: 1));
    await notifier.pause();
    await waitForPause($);

    await waitForCondition(
      $,
      () async => (await items.getById(itemId))!.isHeard,
      description: 'episode marked heard',
    );
    final item = await items.getById(itemId);
    expect(item!.lastPositionMs, 0, reason: 'a replay starts at the top');
    expect(container.read(playerProvider).isFinished, isTrue);

    await stopPlayback($);
  });

  patrolTest('playing to the end marks heard', ($) async {
    await pumpApp($, prefs: {'onboarding_complete': true});
    await clearAppState($);

    final container = getContainer($);
    final episode = await getStableTestEpisode(container);
    final itemId = await insertTestEpisode($, episode);

    final notifier = container.read(playerProvider.notifier);
    final items = container.read(tileItemRepositoryProvider);

    var item = await items.getById(itemId);
    expect(item!.isHeard, isFalse);
    await _resumeAt60Percent($, itemId, episode);

    unawaited(notifier.playCard(itemId));
    await waitForPlayback($);
    await waitForDurationKnown($);

    final duration = container.read(playerProvider).durationMs;
    await notifier.seek(duration - 3000);

    await waitForCondition(
      $,
      () async => container.read(playerProvider).isFinished,
      description: 'the backend reports the end',
      timeout: const Duration(seconds: 15),
    );
    await waitForCondition(
      $,
      () async => (await items.getById(itemId))!.isHeard,
      description: 'episode marked heard',
    );
    item = await items.getById(itemId);
    expect(item!.lastPositionMs, 0, reason: 'a replay starts at the top');

    await stopPlayback($);
  });

  patrolTest('skipping to the end does not mark heard', ($) async {
    // A kid jumping to the last minute and letting it run out has not
    // heard the episode (seen 2026-10 with Spotify chapters).
    await pumpApp($, prefs: {'onboarding_complete': true});
    await clearAppState($);

    final container = getContainer($);
    final episode = await getStableTestEpisode(container);
    final itemId = await insertTestEpisode($, episode);

    final notifier = container.read(playerProvider.notifier);
    final items = container.read(tileItemRepositoryProvider);

    unawaited(notifier.playCard(itemId));
    await waitForPlayback($);
    await waitForDurationKnown($);

    final duration = container.read(playerProvider).durationMs;
    await notifier.seek(duration - 3000);
    await waitForCondition(
      $,
      () async => !container.read(playerProvider).isPlaying,
      description: 'playback reaches the end',
      timeout: const Duration(seconds: 15),
    );
    await $.pump(const Duration(seconds: 2));

    expect((await items.getById(itemId))!.isHeard, isFalse);
    expect(container.read(playerProvider).isFinished, isFalse);

    await stopPlayback($);
  });
}
