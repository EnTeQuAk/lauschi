/// Integration test helpers for ARD Audiothek flows.
///
/// Provides stable test fixtures, audio state waiting, and database
/// setup/teardown for playback tests.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/ard/ard_api.dart';
import 'package:lauschi/core/database/tile_item_repository.dart';
import 'package:lauschi/core/database/tile_repository.dart';
import 'package:lauschi/features/player/player_provider.dart';
import 'package:patrol/patrol.dart';

import 'helpers.dart';

// ── Stable Test Fixtures ───────────────────────────────────────────────────

/// Shows known to have playable audio and many episodes.
/// Ordered by preference — first match wins.
///
/// Ohrenbär: 600+ episodes with MP3 audio, ~5-10 min each.
/// Figarino: 400+ episodes with MP3 audio, ~20 min each.
const _stableShowIds = [
  '25705746', // Ohrenbär (rbb)
  '63331210', // Figarinos Fahrradladen (MDR)
  '50259718', // Krümelgeschichten
];

/// Minimum episode duration in seconds for reliable tests.
const _minimumDurationSeconds = 30;

/// Gets a stable, playable ARD episode for testing.
///
/// Tries each show in [_stableShowIds] until finding an episode with
/// audio and sufficient duration. Throws [TestFailure] if none found.
Future<TestArdEpisode> getStableTestEpisode(
  ProviderContainer container,
) async {
  final api = container.read(ardApiProvider);

  for (final showId in _stableShowIds) {
    try {
      final page = await api.getItems(programSetId: showId, first: 5);
      final suitable =
          page.items.where((item) {
            return item.bestAudioUrl != null &&
                item.duration >= _minimumDurationSeconds;
          }).firstOrNull;

      if (suitable != null) {
        // Also fetch show title for the tile name.
        final show = await api.getProgramSet(showId);
        return TestArdEpisode(
          showId: showId,
          showTitle: show?.title ?? 'ARD Test',
          episodeId: suitable.id,
          episodeTitle: suitable.title,
          audioUrl: suitable.bestAudioUrl!,
          durationSeconds: suitable.duration,
          providerUri: suitable.providerUri,
        );
      }
    } on Exception catch (e) {
      // ignore: avoid_print -- test diagnostics, not user-facing.
      print('Show $showId unavailable: $e');
      continue;
    }
  }

  fail(
    'No playable ARD content found. '
    'Checked shows: $_stableShowIds. '
    'ARD API may be down or content expired.',
  );
}

/// Inserts an ungrouped ARD episode item into the database.
///
/// Ungrouped items appear directly in the kid home grid as `TileItem` widgets.
/// This is simpler than creating a tile (group) and avoids the extra
/// tile-detail navigation step.
Future<String> insertTestEpisode(
  PatrolIntegrationTester $,
  TestArdEpisode episode,
) async {
  final container = getContainer($);
  final items = container.read(tileItemRepositoryProvider);

  final itemId = await items.insertArdEpisode(
    title: episode.episodeTitle,
    providerUri: episode.providerUri,
    audioUrl: episode.audioUrl,
    durationMs: episode.durationSeconds * 1000,
  );

  // Let Drift streams propagate to the UI.
  await pumpFrames($);

  return itemId;
}

/// Creates a tile (group) with an ARD episode inside it.
///
/// Used when testing tile-based flows (tile detail screen, multi-episode tiles).
/// The tile shows as a `TileCard` in the kid grid — tap opens tile detail.
Future<({String tileId, String itemId})> insertTestTileWithEpisode(
  PatrolIntegrationTester $,
  TestArdEpisode episode, {
  String? title,
}) async {
  final container = getContainer($);
  final tiles = container.read(tileRepositoryProvider);
  final items = container.read(tileItemRepositoryProvider);

  final tileId = await tiles.insert(
    title: title ?? 'Test: ${episode.showTitle}',
  );

  final itemId = await items.insertArdEpisode(
    title: episode.episodeTitle,
    providerUri: episode.providerUri,
    audioUrl: episode.audioUrl,
    durationMs: episode.durationSeconds * 1000,
    tileId: tileId,
  );

  await pumpFrames($);

  return (tileId: tileId, itemId: itemId);
}

// ── Provider Access ────────────────────────────────────────────────────────

/// Extracts the [ProviderContainer] from the widget tree.
ProviderContainer getContainer(PatrolIntegrationTester $) {
  return ProviderScope.containerOf(
    $.tester.element(find.byType(MaterialApp)),
  );
}

// ── Audio State Waiting ────────────────────────────────────────────────────

/// Waits for playback to actually start.
///
/// Checks `isPlaying` only — `isLoading` can be transiently true while
/// the StreamPlayer stream fires state updates before `playCard` completes.
/// Polls every 200ms. Fails fast on errors.
Future<void> waitForPlayback(
  PatrolIntegrationTester $, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final container = getContainer($);
  final sw = Stopwatch()..start();

  while (sw.elapsed < timeout) {
    final state = container.read(playerProvider);

    if (state.error != null) {
      fail('Playback error: ${state.error}');
    }
    if (state.isPlaying) {
      return;
    }

    await $.pump(const Duration(milliseconds: 200));
  }

  final state = container.read(playerProvider);
  fail(
    'Playback did not start within ${timeout.inSeconds}s. '
    'State: isPlaying=${state.isPlaying}, isLoading=${state.isLoading}, '
    'isReady=${state.isReady}, error=${state.error}',
  );
}

/// Waits for playback to pause. Fails fast on errors.
Future<void> waitForPause(
  PatrolIntegrationTester $, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final container = getContainer($);
  final sw = Stopwatch()..start();

  while (sw.elapsed < timeout) {
    final state = container.read(playerProvider);
    if (state.error != null) {
      fail('Playback error while waiting for pause: ${state.error}');
    }
    if (!state.isPlaying) return;
    await $.pump(const Duration(milliseconds: 100));
  }

  fail('Playback did not pause within ${timeout.inSeconds}s');
}

/// Polls until [condition] returns true. Fails on timeout.
Future<void> waitForCondition(
  PatrolIntegrationTester $,
  Future<bool> Function() condition, {
  String description = 'condition',
  Duration timeout = const Duration(seconds: 5),
}) async {
  final sw = Stopwatch()..start();

  while (sw.elapsed < timeout) {
    if (await condition()) return;
    await $.pump(const Duration(milliseconds: 200));
  }

  fail('$description not met within ${timeout.inSeconds}s');
}

/// Current position in milliseconds.
int currentPositionMs(PatrolIntegrationTester $) {
  return getContainer($).read(playerProvider).positionMs;
}

/// Stops playback — call in teardown.
Future<void> stopPlayback(PatrolIntegrationTester $) async {
  try {
    await getContainer($).read(playerProvider.notifier).pause();
  } on Exception {
    // Swallow — player may already be disposed.
  }
}

// ── Test Data ──────────────────────────────────────────────────────────────

class TestArdEpisode {
  const TestArdEpisode({
    required this.showId,
    required this.showTitle,
    required this.episodeId,
    required this.episodeTitle,
    required this.audioUrl,
    required this.durationSeconds,
    required this.providerUri,
  });

  final String showId;
  final String showTitle;
  final String episodeId;
  final String episodeTitle;
  final String audioUrl;
  final int durationSeconds;
  final String providerUri;
}
