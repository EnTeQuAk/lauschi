/// ARD Playback: when an episode counts as heard.
///
/// An episode is heard when the audio reaches its end (just_audio reports
/// it explicitly), or when the kid leaves it with at most
/// min(10 %, 4 minutes) left, skipping the closing credits.
library;

import 'dart:async' show unawaited;

import 'package:flutter_test/flutter_test.dart';
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

void main() {
  patrolTest('pausing well before the end does not mark heard', ($) async {
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
}
