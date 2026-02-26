import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lauschi/core/database/app_database.dart';
import 'package:lauschi/core/log.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:uuid/uuid.dart';

part 'tile_item_repository.g.dart';

const _uuid = Uuid();
const _tag = 'TileItemRepo';

/// CRUD operations for tile items (DB table: `cards`).
class TileItemRepository {
  TileItemRepository(this._db);

  final AppDatabase _db;

  /// Watch all items ordered by sortOrder.
  Stream<List<TileItem>> watchAll() {
    return (_db.select(_db.cards)
      ..orderBy([(t) => OrderingTerm.asc(t.sortOrder)])).watch();
  }

  /// Get all items ordered by sortOrder.
  Future<List<TileItem>> getAll() {
    return (_db.select(_db.cards)
      ..orderBy([(t) => OrderingTerm.asc(t.sortOrder)])).get();
  }

  /// Get a single item by ID.
  Future<TileItem?> getById(String id) {
    return (_db.select(_db.cards)
      ..where((t) => t.id.equals(id))).getSingleOrNull();
  }

  /// Insert a new item. Returns the generated ID.
  Future<String> insert({
    required String title,
    required String providerUri,
    required String cardType,
    String? coverUrl,
    String provider = 'spotify',
    List<String>? spotifyArtistIds,
    int totalTracks = 0,
  }) async {
    final id = _uuid.v4();

    // Auto-increment sortOrder
    final maxOrder =
        await _db
            .customSelect(
              'SELECT COALESCE(MAX(sort_order), -1) AS max_order FROM cards',
            )
            .getSingle();
    final nextOrder = (maxOrder.read<int>('max_order')) + 1;

    await _db
        .into(_db.cards)
        .insert(
          CardsCompanion.insert(
            id: id,
            title: title,
            cardType: cardType,
            providerUri: providerUri,
            coverUrl: Value(coverUrl),
            provider: Value(provider),
            sortOrder: Value(nextOrder),
            spotifyArtistIds:
                spotifyArtistIds != null && spotifyArtistIds.isNotEmpty
                    ? Value(spotifyArtistIds.join(','))
                    : const Value(null),
            totalTracks: Value(totalTracks),
          ),
        );

    Log.info(
      _tag,
      'Item added',
      data: {'title': title, 'provider': provider},
    );
    return id;
  }

  /// Insert an item only if the providerUri doesn't already exist.
  /// Returns the ID (existing or new).
  Future<String> insertIfAbsent({
    required String title,
    required String providerUri,
    required String cardType,
    String? coverUrl,
    String provider = 'spotify',
    List<String>? spotifyArtistIds,
    int totalTracks = 0,
  }) async {
    final existing =
        await (_db.select(_db.cards)
          ..where((t) => t.providerUri.equals(providerUri))).getSingleOrNull();

    if (existing != null) return existing.id;

    return insert(
      title: title,
      providerUri: providerUri,
      cardType: cardType,
      coverUrl: coverUrl,
      provider: provider,
      spotifyArtistIds: spotifyArtistIds,
      totalTracks: totalTracks,
    );
  }

  /// Update sort order for multiple items.
  Future<void> reorder(List<String> idsInOrder) async {
    await _db.transaction(() async {
      for (var i = 0; i < idsInOrder.length; i++) {
        await (_db.update(_db.cards)..where(
          (t) => t.id.equals(idsInOrder[i]),
        )).write(CardsCompanion(sortOrder: Value(i)));
      }
    });
  }

  /// Save playback position for an item.
  Future<void> savePosition({
    required String itemId,
    required String trackUri,
    required int positionMs,
    int trackNumber = 0,
  }) async {
    await (_db.update(_db.cards)..where((t) => t.id.equals(itemId))).write(
      CardsCompanion(
        lastTrackUri: Value(trackUri),
        lastTrackNumber: Value(trackNumber),
        lastPositionMs: Value(positionMs),
        lastPlayedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Get the most recently played item (for resume on app launch).
  Future<TileItem?> lastPlayed() {
    return (_db.select(_db.cards)
          ..where((t) => t.lastPlayedAt.isNotNull())
          ..orderBy([(t) => OrderingTerm.desc(t.lastPlayedAt)])
          ..limit(1))
        .getSingleOrNull();
  }

  /// Find an item by its provider URI.
  Future<TileItem?> getByProviderUri(String uri) {
    return (_db.select(_db.cards)
      ..where((t) => t.providerUri.equals(uri))).getSingleOrNull();
  }

  /// Delete an item by ID.
  Future<void> delete(String id) async {
    await (_db.delete(_db.cards)..where((t) => t.id.equals(id))).go();
    Log.info(_tag, 'Item deleted', data: {'id': id});
  }

  /// Delete all items.
  Future<void> deleteAll() async {
    await _db.delete(_db.cards).go();
  }

  /// Delete all items in a tile.
  Future<int> deleteByTile(String tileId) async {
    final count =
        await (_db.delete(_db.cards)
          ..where((t) => t.groupId.equals(tileId))).go();
    Log.info(
      _tag,
      'Deleted items by tile',
      data: {'tileId': tileId, 'count': '$count'},
    );
    return count;
  }

  /// Assign an item to a tile with optional episode number.
  Future<void> assignToTile({
    required String itemId,
    required String tileId,
    int? episodeNumber,
  }) async {
    await (_db.update(_db.cards)..where((t) => t.id.equals(itemId))).write(
      CardsCompanion(
        groupId: Value(tileId),
        episodeNumber: Value(episodeNumber),
      ),
    );
    Log.info(
      _tag,
      'Item assigned to tile',
      data: {
        'itemId': itemId,
        'tileId': tileId,
        if (episodeNumber != null) 'episode': episodeNumber,
      },
    );
  }

  /// Remove an item from its tile.
  Future<void> removeFromTile(String itemId) async {
    await (_db.update(_db.cards)..where((t) => t.id.equals(itemId))).write(
      const CardsCompanion(
        groupId: Value(null),
        episodeNumber: Value(null),
      ),
    );
  }

  /// Mark an item as heard.
  Future<void> markHeard(String itemId) async {
    await (_db.update(_db.cards)..where((t) => t.id.equals(itemId))).write(
      const CardsCompanion(isHeard: Value(true)),
    );
    Log.info(_tag, 'Item marked heard', data: {'itemId': itemId});
  }

  /// Mark an item as unheard.
  Future<void> markUnheard(String itemId) async {
    await (_db.update(_db.cards)..where((t) => t.id.equals(itemId))).write(
      const CardsCompanion(isHeard: Value(false)),
    );
  }

  /// Set ARD-specific fields after initial insert (audio URL, duration, tile).
  Future<void> updateArdFields({
    required String itemId,
    String? audioUrl,
    int? durationMs,
    DateTime? availableUntil,
    String? tileId,
    int? episodeNumber,
  }) async {
    await (_db.update(_db.cards)..where((t) => t.id.equals(itemId))).write(
      CardsCompanion(
        audioUrl: audioUrl != null ? Value(audioUrl) : const Value.absent(),
        durationMs:
            durationMs != null ? Value(durationMs) : const Value.absent(),
        availableUntil:
            availableUntil != null
                ? Value(availableUntil)
                : const Value.absent(),
        groupId: tileId != null ? Value(tileId) : const Value.absent(),
        episodeNumber:
            episodeNumber != null ? Value(episodeNumber) : const Value.absent(),
      ),
    );
  }

  /// Insert an ARD Audiothek episode as an item in a single transaction.
  ///
  /// Combines insertIfAbsent + updateArdFields atomically — if either
  /// step fails, neither is committed.
  Future<String> insertArdEpisode({
    required String title,
    required String providerUri,
    required String audioUrl,
    String? coverUrl,
    int? durationMs,
    DateTime? availableUntil,
    String? tileId,
    int? episodeNumber,
  }) {
    return _db.transaction(() async {
      final id = await insertIfAbsent(
        title: title,
        providerUri: providerUri,
        cardType: 'episode',
        provider: 'ard_audiothek',
        coverUrl: coverUrl,
      );
      await updateArdFields(
        itemId: id,
        audioUrl: audioUrl,
        durationMs: durationMs,
        availableUntil: availableUntil,
        tileId: tileId,
        episodeNumber: episodeNumber,
      );
      return id;
    });
  }

  /// Set totalTracks for an item (used by data migration backfill).
  Future<void> updateTotalTracks({
    required String itemId,
    required int totalTracks,
  }) async {
    await (_db.update(_db.cards)..where((t) => t.id.equals(itemId))).write(
      CardsCompanion(totalTracks: Value(totalTracks)),
    );
  }

  /// Get ungrouped items as a one-shot fetch.
  Future<List<TileItem>> getUngrouped() {
    return (_db.select(_db.cards)
          ..where((t) => t.groupId.isNull())
          ..orderBy([(t) => OrderingTerm.asc(t.sortOrder)]))
        .get();
  }

  /// Watch ungrouped items (top-level items on kid home).
  Stream<List<TileItem>> watchUngrouped() {
    return (_db.select(_db.cards)
          ..where((t) => t.groupId.isNull())
          ..orderBy([(t) => OrderingTerm.asc(t.sortOrder)]))
        .watch();
  }
}

@Riverpod(keepAlive: true)
TileItemRepository tileItemRepository(Ref ref) {
  return TileItemRepository(ref.watch(appDatabaseProvider));
}

/// Stream of all tile items, ordered by sortOrder.
final allTileItemsProvider = StreamProvider<List<TileItem>>((ref) {
  return ref.watch(tileItemRepositoryProvider).watchAll();
});

/// Stream of ungrouped items (top-level, not in any tile).
final ungroupedItemsProvider = StreamProvider<List<TileItem>>((ref) {
  return ref.watch(tileItemRepositoryProvider).watchUngrouped();
});

/// Whether a [TileItem] has expired based on its `availableUntil` field.
bool isItemExpired(TileItem item, {DateTime? now}) {
  if (item.availableUntil == null) return false;
  return item.availableUntil!.isBefore(now ?? DateTime.now());
}

/// Per-tile item counts and heard progress, derived from allTileItemsProvider.
/// Avoids N+1 queries when rendering the kid home grid.
/// Excludes expired items so kids see accurate episode counts.
final tileProgressProvider = Provider<Map<String, ({int total, int heard})>>((
  ref,
) {
  final items = ref.watch(allTileItemsProvider).value ?? [];
  final now = DateTime.now();
  final result = <String, ({int total, int heard})>{};
  for (final item in items) {
    final tid = item.groupId;
    if (tid == null) continue;
    if (isItemExpired(item, now: now)) continue;
    final prev = result[tid] ?? (total: 0, heard: 0);
    result[tid] = (
      total: prev.total + 1,
      heard: prev.heard + (item.isHeard ? 1 : 0),
    );
  }
  return result;
});

/// Set of provider URIs already in the collection.
///
/// Reactive — updates automatically when items are added or removed from
/// any screen. Replaces manual _existingUris bookkeeping in browse screens.
final existingItemUrisProvider = Provider<Set<String>>((ref) {
  final items = ref.watch(allTileItemsProvider).value ?? [];
  return items.map((i) => i.providerUri).toSet();
});
