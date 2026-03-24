/// Cross-provider playback smoke tests.
///
/// Verifies basic playback behaviors work identically across all providers:
/// play, pause, resume, position advances, duration populated.
///
/// All three providers must be authenticated on the test device.
library;

import 'dart:async' show unawaited;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/apple_music/apple_music_session.dart';
import 'package:lauschi/core/database/tile_item_repository.dart';
import 'package:lauschi/core/database/tile_repository.dart';
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

Future<String> _setupSpotify(
  PatrolIntegrationTester $,
  ProviderContainer container,
) async {
  final session = container.read(spotifySessionProvider);
  expect(
    session,
    isA<SpotifyAuthenticated>(),
    reason: 'Spotify must be authenticated',
  );

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
    provider: ProviderType.spotify,
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
  final session = container.read(appleMusicSessionProvider);
  expect(
    session,
    isA<AppleMusicAuthenticated>(),
    reason: 'Apple Music must be authenticated',
  );

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
  final notifier = container.read(playerProvider.notifier);
  unawaited(notifier.playCard(itemId));
  await waitForPlayback($, timeout: const Duration(seconds: 30));

  final state = container.read(playerProvider);
  expect(state.isPlaying, isTrue);
  expect(state.activeCardId, itemId);
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
  final pausedPos = currentPositionMs($);
  expect(pausedPos, greaterThan(0));

  await notifier.resume();
  await waitForPlayback($);
  await $.pump(const Duration(seconds: 3));
  expect(currentPositionMs($), greaterThan(pausedPos));
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
    await _assertPlayStarts($, id);
    await stopPlayback($);
  });

  patrolTest('[Spotify] pause stops playback, resume continues', ($) async {
    await pumpApp($, prefs: {'onboarding_complete': true});
    final c = getContainer($);
    final id = await _setupSpotify($, c);
    await _assertPauseResume($, id);
    await stopPlayback($);
  });

  patrolTest('[Spotify] duration is populated', ($) async {
    await pumpApp($, prefs: {'onboarding_complete': true});
    final c = getContainer($);
    final id = await _setupSpotify($, c);
    await _assertDuration($, id);
    await stopPlayback($);
  });

  patrolTest('[Spotify] position advances', ($) async {
    await pumpApp($, prefs: {'onboarding_complete': true});
    final c = getContainer($);
    final id = await _setupSpotify($, c);
    await _assertPositionAdvances($, id);
    await stopPlayback($);
  });

  // ── Apple Music tests ─────────────────────────────────────────────────────

  patrolTest('[AppleMusic] play starts and reports isPlaying', ($) async {
    await pumpApp($, prefs: {'onboarding_complete': true});
    final c = getContainer($);
    final id = await _setupAppleMusic($, c);
    await _assertPlayStarts($, id);
    await stopPlayback($);
  });

  patrolTest('[AppleMusic] pause stops playback, resume continues', ($) async {
    await pumpApp($, prefs: {'onboarding_complete': true});
    final c = getContainer($);
    final id = await _setupAppleMusic($, c);
    await _assertPauseResume($, id);
    await stopPlayback($);
  });

  patrolTest('[AppleMusic] duration is populated', ($) async {
    await pumpApp($, prefs: {'onboarding_complete': true});
    final c = getContainer($);
    final id = await _setupAppleMusic($, c);
    await _assertDuration($, id);
    await stopPlayback($);
  });

  patrolTest('[AppleMusic] position advances', ($) async {
    await pumpApp($, prefs: {'onboarding_complete': true});
    final c = getContainer($);
    final id = await _setupAppleMusic($, c);
    await _assertPositionAdvances($, id);
    await stopPlayback($);
  });
}
