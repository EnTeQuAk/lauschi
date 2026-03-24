/// Rapid cross-provider switching: ARD → Spotify → Apple Music.
///
/// Verifies that switching between different provider backends rapidly
/// doesn't crash, and the last-requested provider wins.
library;

import 'dart:async' show unawaited;

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

void main() {
  patrolTest(
    'rapid cross-provider switching settles on last provider',
    ($) async {
      await pumpApp($, prefs: {'onboarding_complete': true});
      final container = getContainer($);
      final notifier = container.read(playerProvider.notifier);

      // Set up content from all three providers.
      final ardEpisode = await getStableTestEpisode(container);
      final ardId = await insertTestEpisode($, ardEpisode);

      final spotifySession = container.read(spotifySessionProvider);
      expect(
        spotifySession,
        isA<SpotifyAuthenticated>(),
        reason: 'Spotify must be authenticated',
      );
      final spotifyApi = container.read(spotifySessionProvider.notifier).api;
      final spotifyResults = await spotifyApi.searchAlbums('TKKG');
      expect(spotifyResults.albums, isNotEmpty);
      final spotifyAlbum = spotifyResults.albums.first;
      final items = container.read(tileItemRepositoryProvider);
      final tiles = container.read(tileRepositoryProvider);
      final spotifyTileId = await tiles.insert(title: 'Spotify Rapid Test');
      final spotifyId = await items.insertIfAbsent(
        title: spotifyAlbum.name,
        providerUri: spotifyAlbum.uri,
        cardType: 'album',
        coverUrl: spotifyAlbum.imageUrl,
        totalTracks: spotifyAlbum.totalTracks,
      );
      await items.assignToTile(itemId: spotifyId, tileId: spotifyTileId);

      final amSession = container.read(appleMusicSessionProvider);
      expect(
        amSession,
        isA<AppleMusicAuthenticated>(),
        reason: 'Apple Music must be authenticated',
      );
      final amApi = container.read(appleMusicSessionProvider.notifier).api;
      final amResults = await amApi.searchAlbums('Benjamin Blümchen');
      expect(amResults, isNotEmpty);
      final amAlbum = amResults.first;
      final amTileId = await tiles.insert(title: 'Apple Music Rapid Test');
      final amId = await items.insertIfAbsent(
        title: amAlbum.name,
        providerUri: ProviderType.appleMusic.albumUri(amAlbum.id),
        cardType: 'album',
        provider: ProviderType.appleMusic,
        coverUrl: amAlbum.artworkUrlForSize(200),
        totalTracks: amAlbum.trackCount,
      );
      await items.assignToTile(itemId: amId, tileId: amTileId);
      await pumpFrames($);

      // Rapid fire: ARD → Spotify → Apple Music without waiting.
      // The generation counter in PlayerNotifier should ensure only
      // the last one wins.
      unawaited(notifier.playCard(ardId));
      unawaited(notifier.playCard(spotifyId));
      unawaited(notifier.playCard(amId));

      // Wait for the last provider to start playing.
      await waitForPlayback($, timeout: const Duration(seconds: 45));

      // The last-requested card should win.
      final state = container.read(playerProvider);
      expect(
        state.activeCardId,
        amId,
        reason: 'Last playCard call (Apple Music) should win',
      );
      expect(state.isPlaying, isTrue);
      expect(
        state.error,
        isNull,
        reason: 'No error from rapid cross-provider switching',
      );
      expect(
        state.positionMs,
        lessThan(5000),
        reason: 'Should be near start of the winning track',
      );

      await stopPlayback($);
    },
  );
}
