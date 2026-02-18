import 'package:flutter/foundation.dart';
import 'package:lauschi/core/database/card_repository.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/spotify/spotify_api.dart';

const _tag = 'SeedData';

/// Test audiobooks for development.
///
/// See docs/accessibility.md § "Test Content — Spotify URIs" for rationale.
const seedAlbumIds = [
  '6cW515exmfZuwkDA6Poxlr', // Yakari - Folge 1
  '7MJxrA8d1DHowkJtvIUrsk', // LEGO Ninjago - Folge 1
  '5O8o7vJ8WCFM9l0CBFWLkx', // Die Schnecke und der Buckelwal (Hörspiel)
  '3ufkKdzYUCnOplUlzPHeHQ', // Die Schnecke und der Buckelwal (ungekürzt)
  '3ITUJBzcS3OzO2YIJKXRbA', // PAW Patrol - Folgen 1-4
  '1YF2DKgFdvXItvrZmdxssn', // PAW Patrol - Der Mighty Kinofilm
  '2CRvRuBjaCYAvtTtTen8Z5', // Spidey - Folge 1
  '5cPNQ63oqUjhbkOpTJ3kgS', // SimsalaGrimm - Die Bremer Stadtmusikanten
];

/// Populate the card collection with test audiobooks from Spotify.
///
/// Fetches metadata from the Spotify Web API and inserts cards.
/// Idempotent — skips albums already in the collection.
/// Only available in debug builds.
Future<void> seedTestContent({
  required CardRepository cards,
  required SpotifyApi api,
}) async {
  if (!kDebugMode) {
    Log.warn(_tag, 'Seed data only available in debug builds');
    return;
  }

  if (!api.hasToken) {
    Log.warn(_tag, 'Cannot seed — no Spotify token');
    return;
  }

  Log.info(_tag, 'Seeding test content (${seedAlbumIds.length} albums)');

  var added = 0;
  for (final albumId in seedAlbumIds) {
    try {
      final album = await api.getAlbum(albumId);
      if (album == null) {
        Log.warn(_tag, 'Album not found', data: {'id': albumId});
        continue;
      }

      await cards.insertIfAbsent(
        title: album.name,
        providerUri: album.uri,
        cardType: 'album',
        coverUrl: album.imageUrl,
      );
      added++;
      Log.debug(_tag, 'Seeded', data: {'title': album.name});
    } on Exception catch (e) {
      Log.error(_tag, 'Failed to seed album', data: {'id': albumId}, exception: e);
    }
  }

  Log.info(_tag, 'Seed complete', data: {'added': '$added'});
}
