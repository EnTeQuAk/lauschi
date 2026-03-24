/// Cross-provider playback smoke tests.
///
/// Parameterized tests that verify basic playback behaviors work identically
/// across all providers: play, pause, resume, position advances, duration
/// populated. Each provider has its own setup that discovers playable content,
/// skipping if the provider isn't authenticated.
///
/// ARD Audiothek: always available (free, no auth).
/// Spotify: requires active session (skips if not connected).
/// Apple Music: requires active session (skips if not connected).
library;

import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/apple_music/apple_music_session.dart';
import 'package:lauschi/core/database/tile_item_repository.dart';
import 'package:lauschi/core/database/tile_repository.dart';
import 'package:lauschi/core/feature_flags.dart';
import 'package:lauschi/core/providers/provider_type.dart';
import 'package:lauschi/core/spotify/spotify_session.dart';
import 'package:lauschi/features/player/player_provider.dart';
import 'package:patrol/patrol.dart';

import 'ard_helpers.dart';
import 'helpers.dart';

// ── Provider-specific content setup ─────────────────────────────────────────

/// Discovers playable content for a provider.
/// Returns a tile item ID ready for playCard(), or null if the provider
/// isn't available (no auth, no content).
typedef ContentSetup =
    Future<String?> Function(
      PatrolIntegrationTester $,
      ProviderContainer container,
    );

/// ARD: always available. Discovers a stable episode from the API.
Future<String?> _setupArd(
  PatrolIntegrationTester $,
  ProviderContainer container,
) async {
  try {
    final episode = await getStableTestEpisode(container);
    return insertTestEpisode($, episode);
  } on TestFailure {
    // ARD API down or no playable content found.
    return null;
  }
}

/// Spotify: requires active session. Uses search to find a playable album.
Future<String?> _setupSpotify(
  PatrolIntegrationTester $,
  ProviderContainer container,
) async {
  if (!FeatureFlags.enableSpotify) return null;

  final session = container.read(spotifySessionProvider);
  if (session is! SpotifyAuthenticated) return null;

  // Search for a well-known, stable album.
  try {
    final api = container.read(spotifySessionProvider.notifier).api;
    final results = await api.searchAlbums('Die drei Fragezeichen');
    if (results.albums.isEmpty) return null;

    final album = results.albums.first;
    final items = container.read(tileItemRepositoryProvider);
    final tiles = container.read(tileRepositoryProvider);

    final tileId = await tiles.insert(
      title: 'Spotify Test',
      contentType: 'hoerspiel',
    );
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
  } on Exception {
    return null;
  }
}

/// Apple Music: requires active session. Uses API to find a playable album.
Future<String?> _setupAppleMusic(
  PatrolIntegrationTester $,
  ProviderContainer container,
) async {
  if (!FeatureFlags.enableAppleMusic) return null;

  final session = container.read(appleMusicSessionProvider);
  if (session is! AppleMusicAuthenticated) return null;

  try {
    final api = container.read(appleMusicSessionProvider.notifier).api;
    final results = await api.searchAlbums('Asterix');
    if (results.isEmpty) return null;

    final album = results.first;
    final items = container.read(tileItemRepositoryProvider);
    final tiles = container.read(tileRepositoryProvider);

    final tileId = await tiles.insert(
      title: 'Apple Music Test',
      contentType: 'hoerspiel',
    );
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
  } on Exception {
    return null;
  }
}

// ── Parameterized test runner ───────────────────────────────────────────────

/// Test cases that apply to every provider.
void _runPlaybackTests(String providerName, ContentSetup setup) {
  patrolTest(
    '[$providerName] play starts and reports isPlaying',
    ($) async {
      await pumpApp($, prefs: {'onboarding_complete': true});
      final container = getContainer($);

      final itemId = await setup($, container);
      if (itemId == null) {
        // Provider not available; skip gracefully.
        // ignore: avoid_print
        print('SKIP: $providerName not available');
        return;
      }

      final notifier = container.read(playerProvider.notifier);
      unawaited(notifier.playCard(itemId));

      await waitForPlayback($, timeout: const Duration(seconds: 30));

      final state = container.read(playerProvider);
      expect(state.isPlaying, isTrue);
      expect(state.activeCardId, itemId);

      await stopPlayback($);
    },
  );

  patrolTest(
    '[$providerName] pause stops playback, resume continues',
    ($) async {
      await pumpApp($, prefs: {'onboarding_complete': true});
      final container = getContainer($);

      final itemId = await setup($, container);
      if (itemId == null) {
        // ignore: avoid_print
        print('SKIP: $providerName not available');
        return;
      }

      final notifier = container.read(playerProvider.notifier);
      unawaited(notifier.playCard(itemId));
      await waitForPlayback($, timeout: const Duration(seconds: 30));

      // Pause.
      await notifier.pause();
      await waitForPause($);

      final pausedPos = currentPositionMs($);
      expect(pausedPos, greaterThan(0));

      // Resume.
      await notifier.resume();
      await waitForPlayback($);

      // Position should advance past the paused point.
      await $.pump(const Duration(seconds: 3));
      expect(currentPositionMs($), greaterThan(pausedPos));

      await stopPlayback($);
    },
  );

  patrolTest(
    '[$providerName] duration is populated after playback starts',
    ($) async {
      await pumpApp($, prefs: {'onboarding_complete': true});
      final container = getContainer($);

      final itemId = await setup($, container);
      if (itemId == null) {
        // ignore: avoid_print
        print('SKIP: $providerName not available');
        return;
      }

      final notifier = container.read(playerProvider.notifier);
      unawaited(notifier.playCard(itemId));
      await waitForPlayback($, timeout: const Duration(seconds: 30));

      final state = container.read(playerProvider);
      expect(
        state.durationMs,
        greaterThan(0),
        reason: 'Duration should be known after playback starts',
      );

      await stopPlayback($);
    },
  );

  patrolTest(
    '[$providerName] position advances during playback',
    ($) async {
      await pumpApp($, prefs: {'onboarding_complete': true});
      final container = getContainer($);

      final itemId = await setup($, container);
      if (itemId == null) {
        // ignore: avoid_print
        print('SKIP: $providerName not available');
        return;
      }

      final notifier = container.read(playerProvider.notifier);
      unawaited(notifier.playCard(itemId));
      await waitForPlayback($, timeout: const Duration(seconds: 30));

      final pos1 = currentPositionMs($);
      await $.pump(const Duration(seconds: 3));
      final pos2 = currentPositionMs($);

      expect(
        pos2,
        greaterThan(pos1),
        reason: 'Position should advance during playback',
      );

      await stopPlayback($);
    },
  );
}

// ── Test registration ──────────────────────────────────────────────────────

void main() {
  _runPlaybackTests('ARD', _setupArd);
  _runPlaybackTests('Spotify', _setupSpotify);
  _runPlaybackTests('AppleMusic', _setupAppleMusic);
}
