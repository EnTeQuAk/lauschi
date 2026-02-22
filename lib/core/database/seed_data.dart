import 'package:flutter/foundation.dart';
import 'package:lauschi/core/database/card_repository.dart';
import 'package:lauschi/core/database/group_repository.dart';
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
        totalTracks: album.totalTracks,
      );
      added++;
      Log.debug(_tag, 'Seeded', data: {'title': album.name});
    } on Exception catch (e) {
      Log.error(
        _tag,
        'Failed to seed album',
        data: {'id': albumId},
        exception: e,
      );
    }
  }

  Log.info(_tag, 'Seed complete', data: {'added': '$added'});
}

/// ARD Audiothek test items for development.
///
/// These are real, publicly available episodes from the kids category.
/// Audio URLs are direct CDN links (no auth, no DRM).
const _ardSeedItems = [
  (
    title: 'Luigi und Gladiator (1) – Die komplette Hörgeschichte!',
    providerUri: 'ard:item:89204038',
    audioUrl:
        'https://rbbmediapmdp-a.akamaihd.net/content/e1/18/e118f7f0-33d5-4beb-96d0-6c2b9047faef/03313a09-585c-4da1-b81c-f11e3630249b_adf83b2c-2e2b-4e36-8a74-a6bca7c05c42.mp3',
    coverUrl:
        'https://api.ardmediathek.de/image-service/images/urn:ard:image:cf4b6c76016e6585?w=400',
    durationMs: 3504 * 1000, // 58 min
    showTitle: 'Ohrenbär',
  ),
];

/// Populate the card collection with test ARD Audiothek content.
///
/// Creates a group and inserts cards with direct audio URLs.
/// Idempotent — skips items already in the collection.
/// Only available in debug builds.
Future<void> seedArdTestContent({
  required CardRepository cards,
  required GroupRepository groups,
}) async {
  if (!kDebugMode) return;

  Log.info(_tag, 'Seeding ARD test content');

  String? groupId;
  var added = 0;

  for (final item in _ardSeedItems) {
    // Create group from show title on first item.
    groupId ??= await groups
        .findByTitle(item.showTitle)
        .then(
          (g) async => g?.id ?? await groups.insert(title: item.showTitle),
        );

    // insertArdEpisode uses insertIfAbsent internally — only count new inserts.
    final existing = await cards.getByProviderUri(item.providerUri);
    await cards.insertArdEpisode(
      title: item.title,
      providerUri: item.providerUri,
      audioUrl: item.audioUrl,
      coverUrl: item.coverUrl,
      durationMs: item.durationMs,
      groupId: groupId,
    );
    if (existing == null) added++;
  }

  Log.info(_tag, 'ARD seed complete', data: {'added': '$added'});
}
