/// Cross-provider playback smoke tests.
///
/// Verifies basic playback behaviors work identically across all providers:
/// play, pause, resume, position advances, duration populated.
///
/// Spotify and Apple Music tests skip gracefully when the provider isn't
/// authenticated on the test device (tokens not in secure storage).
library;

import 'dart:async' show unawaited;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/apple_music/apple_music_session.dart';
import 'package:lauschi/core/database/tile_item_repository.dart';
import 'package:lauschi/core/database/tile_repository.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/providers/provider_type.dart';
import 'package:lauschi/core/spotify/spotify_session.dart';
import 'package:lauschi/features/player/player_provider.dart';
import 'package:patrol/patrol.dart';

import 'ard_helpers.dart';
import 'helpers.dart';

// ── Content setup per provider ──────────────────────────────────────────────

Future<String> _setupArd(
  PatrolIntegrationTester $,
  ProviderContainer container,
) async {
  final episode = await getStableTestEpisode(container);
  return insertTestEpisode($, episode);
}

/// Wait for a provider session to reach a specific authenticated type.
/// Returns the state if reached, null if timed out.
Future<T?> _waitForAuth<T>(
  PatrolIntegrationTester $,
  Object Function() readState, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final sw = Stopwatch()..start();
  while (sw.elapsed < timeout) {
    final state = readState();
    if (state is T) return state as T;
    await $.pump(const Duration(milliseconds: 500));
  }
  return null;
}

Future<String> _setupSpotify(
  PatrolIntegrationTester $,
  ProviderContainer container,
) async {
  // Wait for Spotify to finish loading stored tokens (async at startup).
  // Returns null to signal "skip" if auth never completes.
  final authenticated = await _waitForAuth<SpotifyAuthenticated>(
    $,
    () => container.read(spotifySessionProvider),
  );
  if (authenticated == null) {
    Log.info('Test', 'Skipping: Spotify not authenticated on this device');
    return ''; // Caller checks empty string = skip
  }

  final api = container.read(spotifySessionProvider.notifier).api;
  final results = await api.searchAlbums('Die drei Fragezeichen');
  expect(
    results.albums,
    isNotEmpty,
    reason: 'Spotify search must return results',
  );

  final album = results.albums.first;
  final items = container.read(tileItemRepositoryProvider);
  final tiles = container.read(tileRepositoryProvider);
  final tileId = await tiles.insert(title: 'Spotify Test');
  final itemId = await items.insertIfAbsent(
    title: album.name,
    providerUri: album.uri,
    cardType: 'album',
    coverUrl: album.imageUrl,
    totalTracks: album.totalTracks,
  );
  await items.assignToTile(itemId: itemId, tileId: tileId);
  await pumpFrames($);
  return itemId;
}

Future<String> _setupAppleMusic(
  PatrolIntegrationTester $,
  ProviderContainer container,
) async {
  // Wait for Apple Music to finish auth. On Android, MusicKit JS token
  // exchange can take 30-60s on cold start.
  final authenticated = await _waitForAuth<AppleMusicAuthenticated>(
    $,
    () => container.read(appleMusicSessionProvider),
    timeout: const Duration(seconds: 60),
  );
  if (authenticated == null) {
    Log.info('Test', 'Skipping: Apple Music not authenticated on this device');
    return '';
  }
  final session = container.read(appleMusicSessionProvider);
  expect(session, isA<AppleMusicAuthenticated>());

  final api = container.read(appleMusicSessionProvider.notifier).api;
  final results = await api.searchAlbums('Asterix');
  expect(results, isNotEmpty, reason: 'Apple Music search must return results');

  final album = results.first;
  final items = container.read(tileItemRepositoryProvider);
  final tiles = container.read(tileRepositoryProvider);
  final tileId = await tiles.insert(title: 'Apple Music Test');
  final itemId = await items.insertIfAbsent(
    title: album.name,
    providerUri: ProviderType.appleMusic.albumUri(album.id),
    cardType: 'album',
    provider: ProviderType.appleMusic,
    coverUrl: album.artworkUrlForSize(200),
    totalTracks: album.trackCount,
  );
  await items.assignToTile(itemId: itemId, tileId: tileId);
  await pumpFrames($);
  return itemId;
}

// ── Shared assertions ───────────────────────────────────────────────────────

Future<void> _assertPlayStarts(PatrolIntegrationTester $, String itemId) async {
  final container = getContainer($);

  // Precondition: not playing before we start.
  final before = container.read(playerProvider);
  expect(before.isPlaying, isFalse, reason: 'Precondition: not playing');
  expect(
    before.activeCardId,
    isNot(itemId),
    reason: 'Precondition: different card or none active',
  );

  final notifier = container.read(playerProvider.notifier);
  unawaited(notifier.playCard(itemId));
  await waitForPlayback($, timeout: const Duration(seconds: 30));

  final state = container.read(playerProvider);
  expect(state.isPlaying, isTrue);
  expect(state.activeCardId, itemId);
  expect(state.error, isNull, reason: 'No error during playback start');
  expect(state.track, isNotNull, reason: 'Track metadata should be set');
  expect(
    state.positionMs,
    lessThan(5000),
    reason: 'Fresh play should start near 0',
  );
}

Future<void> _assertPauseResume(
  PatrolIntegrationTester $,
  String itemId,
) async {
  final container = getContainer($);
  final notifier = container.read(playerProvider.notifier);
  unawaited(notifier.playCard(itemId));
  await waitForPlayback($, timeout: const Duration(seconds: 30));

  await notifier.pause();
  await waitForPause($);

  final pausedState = container.read(playerProvider);
  final pausedPos = pausedState.positionMs;
  expect(pausedPos, greaterThan(0), reason: 'Should have played some audio');
  expect(pausedState.isPlaying, isFalse);
  expect(
    pausedState.track,
    isNotNull,
    reason: 'Track metadata should persist after pause',
  );
  expect(
    pausedState.durationMs,
    greaterThan(0),
    reason: 'Duration should persist after pause',
  );

  // Position should not advance while paused.
  await $.pump(const Duration(seconds: 1));
  final stillPausedPos = currentPositionMs($);
  expect(
    stillPausedPos,
    closeTo(pausedPos, 500),
    reason: 'Position should not advance while paused',
  );

  await notifier.resume();
  await waitForPlayback($);
  await $.pump(const Duration(seconds: 3));

  final resumed = container.read(playerProvider);
  expect(
    resumed.positionMs,
    greaterThan(pausedPos),
    reason: 'Position should advance after resume',
  );
  expect(resumed.isPlaying, isTrue);
  expect(resumed.error, isNull);
}

Future<void> _assertDuration(PatrolIntegrationTester $, String itemId) async {
  final container = getContainer($);
  unawaited(container.read(playerProvider.notifier).playCard(itemId));
  await waitForPlayback($, timeout: const Duration(seconds: 30));
  expect(
    container.read(playerProvider).durationMs,
    greaterThan(0),
    reason: 'Duration should be known after playback starts',
  );
}

Future<void> _assertPositionAdvances(
  PatrolIntegrationTester $,
  String itemId,
) async {
  final container = getContainer($);
  unawaited(container.read(playerProvider.notifier).playCard(itemId));
  await waitForPlayback($, timeout: const Duration(seconds: 30));
  final pos1 = currentPositionMs($);
  await $.pump(const Duration(seconds: 3));
  expect(
    currentPositionMs($),
    greaterThan(pos1),
    reason: 'Position should advance during playback',
  );
}

// ── ARD tests ───────────────────────────────────────────────────────────────

void main() {
  patrolTest('[ARD] play starts and reports isPlaying', ($) async {
    await pumpApp($, prefs: {'onboarding_complete': true});
    final c = getContainer($);
    final id = await _setupArd($, c);
    await _assertPlayStarts($, id);
    await stopPlayback($);
  });

  patrolTest('[ARD] pause stops playback, resume continues', ($) async {
    await pumpApp($, prefs: {'onboarding_complete': true});
    final c = getContainer($);
    final id = await _setupArd($, c);
    await _assertPauseResume($, id);
    await stopPlayback($);
  });

  patrolTest('[ARD] duration is populated', ($) async {
    await pumpApp($, prefs: {'onboarding_complete': true});
    final c = getContainer($);
    final id = await _setupArd($, c);
    await _assertDuration($, id);
    await stopPlayback($);
  });

  patrolTest('[ARD] position advances', ($) async {
    await pumpApp($, prefs: {'onboarding_complete': true});
    final c = getContainer($);
    final id = await _setupArd($, c);
    await _assertPositionAdvances($, id);
    await stopPlayback($);
  });

  // ── Spotify tests ─────────────────────────────────────────────────────────

  patrolTest('[Spotify] play starts and reports isPlaying', ($) async {
    await pumpApp($, prefs: {'onboarding_complete': true});
    final c = getContainer($);
    final id = await _setupSpotify($, c);
    if (id.isEmpty) return; // Provider not available
    await _assertPlayStarts($, id);
    await stopPlayback($);
  });

  patrolTest('[Spotify] pause stops playback, resume continues', ($) async {
    await pumpApp($, prefs: {'onboarding_complete': true});
    final c = getContainer($);
    final id = await _setupSpotify($, c);
    if (id.isEmpty) return; // Provider not available
    await _assertPauseResume($, id);
    await stopPlayback($);
  });

  patrolTest('[Spotify] duration is populated', ($) async {
    await pumpApp($, prefs: {'onboarding_complete': true});
    final c = getContainer($);
    final id = await _setupSpotify($, c);
    if (id.isEmpty) return; // Provider not available
    await _assertDuration($, id);
    await stopPlayback($);
  });

  patrolTest('[Spotify] position advances', ($) async {
    await pumpApp($, prefs: {'onboarding_complete': true});
    final c = getContainer($);
    final id = await _setupSpotify($, c);
    if (id.isEmpty) return; // Provider not available
    await _assertPositionAdvances($, id);
    await stopPlayback($);
  });

  // ── Apple Music tests ─────────────────────────────────────────────────────

  patrolTest('[AppleMusic] play starts and reports isPlaying', ($) async {
    await pumpApp($, prefs: {'onboarding_complete': true});
    final c = getContainer($);
    final id = await _setupAppleMusic($, c);
    if (id.isEmpty) return; // Provider not available
    await _assertPlayStarts($, id);
    await stopPlayback($);
  });

  patrolTest('[AppleMusic] pause stops playback, resume continues', ($) async {
    await pumpApp($, prefs: {'onboarding_complete': true});
    final c = getContainer($);
    final id = await _setupAppleMusic($, c);
    if (id.isEmpty) return; // Provider not available
    await _assertPauseResume($, id);
    await stopPlayback($);
  });

  patrolTest('[AppleMusic] duration is populated', ($) async {
    await pumpApp($, prefs: {'onboarding_complete': true});
    final c = getContainer($);
    final id = await _setupAppleMusic($, c);
    if (id.isEmpty) return; // Provider not available
    await _assertDuration($, id);
    await stopPlayback($);
  });

  patrolTest('[AppleMusic] position advances', ($) async {
    await pumpApp($, prefs: {'onboarding_complete': true});
    final c = getContainer($);
    final id = await _setupAppleMusic($, c);
    if (id.isEmpty) return; // Provider not available
    await _assertPositionAdvances($, id);
    await stopPlayback($);
  });
}
