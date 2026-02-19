import 'dart:async';

import 'package:lauschi/core/database/card_repository.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/spotify/spotify_api.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _tag = 'DataMigration';
const _prefsPrefix = 'data_migration_done_';

/// A named data migration that runs once and requires auth/API access.
///
/// Unlike schema migrations (Drift's onUpgrade), these run at app startup
/// after Spotify auth is established. Use for backfills that need API calls.
typedef DataMigration = Future<void> Function(DataMigrationContext ctx);

/// Context passed to each migration.
class DataMigrationContext {
  const DataMigrationContext({
    required this.cards,
    required this.api,
  });

  final CardRepository cards;
  final SpotifyApi api;
}

/// Registry of all data migrations, in order.
///
/// Each entry is (id, migration). IDs are permanent — never rename or remove
/// completed ones. Append new migrations at the end.
final List<(String, DataMigration)> _migrations = [
  ('backfill_total_tracks_v1', _backfillTotalTracks),
];

/// Run all pending data migrations. Safe to call on every startup.
Future<void> runDataMigrations(DataMigrationContext ctx) async {
  final prefs = await SharedPreferences.getInstance();

  for (final (id, migrate) in _migrations) {
    final key = '$_prefsPrefix$id';
    if (prefs.getBool(key) ?? false) continue;

    Log.info(_tag, 'Running', data: {'migration': id});
    try {
      await migrate(ctx);
      await prefs.setBool(key, true);
      Log.info(_tag, 'Complete', data: {'migration': id});
    } on Exception catch (e) {
      // Don't mark as done — will retry next launch.
      Log.error(_tag, 'Failed', data: {'migration': id}, exception: e);
    }
  }
}

// ---------------------------------------------------------------------------
// Migrations
// ---------------------------------------------------------------------------

/// Backfill totalTracks for cards inserted before schema v5.
Future<void> _backfillTotalTracks(DataMigrationContext ctx) async {
  final allCards = await ctx.cards.getAll();
  final needsBackfill = allCards.where(
    (c) => c.totalTracks == 0 && c.cardType == 'album',
  );

  if (needsBackfill.isEmpty) {
    Log.debug(_tag, 'No cards need totalTracks backfill');
    return;
  }

  // Extract Spotify album IDs from provider URIs (spotify:album:<id>).
  final cardsByAlbumId = <String, List<String>>{};
  for (final card in needsBackfill) {
    final albumId = _spotifyIdFromUri(card.providerUri);
    if (albumId != null) {
      cardsByAlbumId.putIfAbsent(albumId, () => []).add(card.id);
    }
  }

  Log.info(
    _tag,
    'Backfilling totalTracks',
    data: {
      'albums': '${cardsByAlbumId.length}',
    },
  );

  // Fetch in batches of 20 (Spotify API limit).
  final albumIds = cardsByAlbumId.keys.toList();
  for (var i = 0; i < albumIds.length; i += 20) {
    final batch = albumIds.skip(i).take(20).toList();
    final albums = await ctx.api.getAlbums(batch);

    for (final album in albums) {
      final cardIds = cardsByAlbumId[album.id];
      if (cardIds == null) continue;

      for (final cardId in cardIds) {
        await ctx.cards.updateTotalTracks(
          cardId: cardId,
          totalTracks: album.totalTracks,
        );
      }
    }
  }

  Log.info(
    _tag,
    'Backfill complete',
    data: {
      'albums': '${cardsByAlbumId.length}',
    },
  );
}

/// Extract Spotify ID from a URI like "spotify:album:abc123".
String? _spotifyIdFromUri(String uri) {
  final parts = uri.split(':');
  return parts.length == 3 ? parts[2] : null;
}
