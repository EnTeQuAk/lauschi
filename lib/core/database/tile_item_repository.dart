import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lauschi/core/catalog/catalog_service.dart';
import 'package:lauschi/core/database/app_database.dart';
import 'package:lauschi/core/database/tables.dart' show cardOrder;
import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/providers/provider_type.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:uuid/uuid.dart';

part 'tile_item_repository.g.dart';

const _uuid = Uuid();
const _tag = 'TileItemRepo';

/// CRUD operations for tile items (DB table: `cards`).
class TileItemRepository {
  TileItemRepository(this._db);

  final AppDatabase _db;

  /// Watch all items ordered by manual sort order, then episode number.
  Stream<List<TileItem>> watchAll() {
    return (_db.select(_db.cards)..orderBy(cardOrder())).watch();
  }

  /// Get all items ordered by manual sort order, then episode number.
  Future<List<TileItem>> getAll() {
    return (_db.select(_db.cards)..orderBy(cardOrder())).get();
  }

  /// Get a single item by ID.
  Future<TileItem?> getById(String id) {
    return (_db.select(_db.cards)
      ..where((t) => t.id.equals(id))).getSingleOrNull();
  }

  /// Watch a single item by ID. Emits null if the row is missing
  /// (e.g. after delete). Used by the parent item-edit screen so its
  /// title/cover fields stay in sync with concurrent writes.
  Stream<TileItem?> watchById(String id) {
    return (_db.select(_db.cards)
      ..where((t) => t.id.equals(id))).watchSingleOrNull();
  }

  /// Update an item's editable metadata (custom title / cover URL).
  ///
  /// Uses [Value.absent] semantics: omitting a parameter leaves the
  /// column untouched, while passing `null` (via the dedicated `clear*`
  /// flags) wipes the override and restores the original title/cover.
  Future<void> updateMeta({
    required String id,
    String? customTitle,
    bool clearCustomTitle = false,
    String? coverUrl,
    bool clearCoverUrl = false,
  }) async {
    await (_db.update(_db.cards)..where((t) => t.id.equals(id))).write(
      CardsCompanion(
        customTitle:
            clearCustomTitle
                ? const Value(null)
                : customTitle != null
                ? Value(customTitle)
                : const Value.absent(),
        coverUrl:
            clearCoverUrl
                ? const Value(null)
                : coverUrl != null
                ? Value(coverUrl)
                : const Value.absent(),
      ),
    );
    Log.info(_tag, 'Item meta updated', data: {'id': id});
  }

  /// Insert a new item. Returns the generated ID.
  ///
  /// The provider column derives from the [providerUri] prefix
  /// (e.g. 'apple_music:album:123' → apple_music), so the two can
  /// never disagree. Throws [ArgumentError] on unknown prefixes.
  Future<String> insert({
    required String title,
    required String providerUri,
    required String cardType,
    String? coverUrl,
    List<String>? spotifyArtistIds,
    int totalTracks = 0,
  }) async {
    final provider = ProviderType.fromUri(providerUri);
    final id = _uuid.v4();

    await _db
        .into(_db.cards)
        .insert(
          CardsCompanion.insert(
            id: id,
            title: title,
            cardType: cardType,
            providerUri: providerUri,
            coverUrl: Value(coverUrl),
            provider: Value(provider.value),
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
  ///
  /// Runs in a transaction so concurrent calls (double-tap on an add
  /// button) serialize instead of both passing the existence check.
  Future<String> insertIfAbsent({
    required String title,
    required String providerUri,
    required String cardType,
    String? coverUrl,
    List<String>? spotifyArtistIds,
    int totalTracks = 0,
  }) {
    return _db.transaction(() async {
      final existing = await getByProviderUri(providerUri);
      if (existing != null) return existing.id;

      return insert(
        title: title,
        providerUri: providerUri,
        cardType: cardType,
        coverUrl: coverUrl,
        spotifyArtistIds: spotifyArtistIds,
        totalTracks: totalTracks,
      );
    });
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
    Log.debug(_tag, 'Items reordered', data: {'count': '${idsInOrder.length}'});
  }

  /// Reset saved playback position for a single item, so next playback
  /// starts from the beginning instead of resuming.
  ///
  /// Clears lastPlayedAt too, matching clearPositions: a finished
  /// standalone episode (handleAlbumCompleted resets it) that kept its
  /// timestamp would still win lastPlayed() and resume-on-launch at 0.
  /// Also used by integration tests needing a clean position each run.
  Future<void> resetPlaybackPosition(String itemId) async {
    await (_db.update(_db.cards)..where((t) => t.id.equals(itemId))).write(
      const CardsCompanion(
        lastTrackUri: Value(null),
        lastTrackNumber: Value(0),
        lastPositionMs: Value(0),
        lastPlayedAt: Value(null),
      ),
    );
    Log.debug(_tag, 'Position reset', data: {'itemId': itemId});
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
    Log.debug(
      _tag,
      'Position saved',
      data: {
        'itemId': itemId,
        'trackNumber': '$trackNumber',
        'positionMs': '$positionMs',
      },
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
  ///
  /// The providerUri index is not unique; installs that raced the add
  /// flow before [insertIfAbsent] became transactional can hold
  /// duplicate rows. Picking one row keeps lookups working for them.
  Future<TileItem?> getByProviderUri(String uri) {
    return (_db.select(_db.cards)
          ..where((t) => t.providerUri.equals(uri))
          ..limit(1))
        .getSingleOrNull();
  }

  /// Delete an item by ID.
  Future<void> delete(String id) async {
    await (_db.delete(_db.cards)..where((t) => t.id.equals(id))).go();
    Log.info(_tag, 'Item deleted', data: {'id': id});
  }

  /// Mark an item as unavailable (content removed or license expired).
  Future<void> markUnavailable(String id) async {
    await (_db.update(_db.cards)..where((t) => t.id.equals(id))).write(
      CardsCompanion(markedUnavailable: Value(DateTime.now())),
    );
    Log.info(_tag, 'Item marked unavailable', data: {'id': id});
  }

  /// Clear the unavailable flag (content is back).
  Future<void> clearUnavailable(String id) async {
    await (_db.update(_db.cards)..where((t) => t.id.equals(id))).write(
      const CardsCompanion(markedUnavailable: Value(null)),
    );
    Log.info(_tag, 'Item availability restored', data: {'id': id});
  }

  /// Get all items marked unavailable, optionally filtered to those
  /// marked more than [olderThan] ago (for recheck scheduling).
  Future<List<TileItem>> getUnavailable({Duration? olderThan}) {
    final query = _db.select(_db.cards)
      ..where((t) => t.markedUnavailable.isNotNull());
    if (olderThan != null) {
      final cutoff = DateTime.now().subtract(olderThan);
      query.where((t) => t.markedUnavailable.isSmallerThanValue(cutoff));
    }
    return query.get();
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

  /// Assign an item to a tile, optionally setting its episode number.
  ///
  /// Omitting [episodeNumber] leaves the stored number untouched, so a card
  /// moved between tiles keeps its place in the run. It is never used to
  /// clear a number; [removeFromTile] does that when unassigning.
  Future<void> assignToTile({
    required String itemId,
    required String tileId,
    int? episodeNumber,
  }) async {
    await (_db.update(_db.cards)..where((t) => t.id.equals(itemId))).write(
      CardsCompanion(
        groupId: Value(tileId),
        episodeNumber:
            episodeNumber != null ? Value(episodeNumber) : const Value.absent(),
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
        sortOrder: Value(null),
      ),
    );
    Log.info(_tag, 'Item removed from tile', data: {'itemId': itemId});
  }

  /// Mark an item as heard.
  Future<void> markHeard(String itemId) async {
    await (_db.update(_db.cards)..where((t) => t.id.equals(itemId))).write(
      const CardsCompanion(isHeard: Value(true)),
    );
    Log.info(_tag, 'Item marked heard', data: {'itemId': itemId});
  }

  /// Clear saved playback positions for all items in a tile.
  ///
  /// Each tile behaves like a CD player: only one episode can be "in
  /// progress" at a time. This is called in two situations:
  ///
  /// 1. **Episode completes** (no excludeItemId): clears everything,
  ///    including the completed episode. Its position is meaningless
  ///    since it's now marked heard.
  ///
  /// 2. **New episode starts in the same tile** (excludeItemId set):
  ///    clears all positions except the new episode, so the "Weiter"
  ///    badge points at it unambiguously.
  ///
  /// Also clears `lastPlayedAt` so stale timestamps don't confuse
  /// the "in progress" detection in `tileNextUnheardProvider`.
  Future<void> clearPositions(
    String tileId, {
    String? excludeItemId,
  }) async {
    var query = _db.update(_db.cards)..where((t) => t.groupId.equals(tileId));
    if (excludeItemId != null) {
      query = query..where((t) => t.id.equals(excludeItemId).not());
    }
    await query.write(
      const CardsCompanion(
        lastTrackUri: Value(null),
        lastTrackNumber: Value(0),
        lastPositionMs: Value(0),
        lastPlayedAt: Value(null),
      ),
    );
    Log.info(
      _tag,
      'Positions cleared',
      data: {'tileId': tileId, 'excludeItemId': excludeItemId ?? 'none'},
    );
  }

  /// Adopt the catalog's episode numbers for items whose stored number
  /// disagrees. Returns how many rows changed.
  ///
  /// Episode numbers are facts about an album, derived once in the
  /// curation pipeline (docs/catalog-episode-numbers.md), so a stored
  /// number that differs is stale. Running this whenever the catalog and
  /// database are both available repairs installs that predate the app
  /// reading curated numbers, and keeps repairing them as the catalog is
  /// corrected — the 2026-07 Hui Buh re-labelling moved all six of that
  /// series' episodes, and existing tiles would otherwise keep the wrong
  /// numbers indefinitely.
  ///
  /// Only the episode number column is written. A parent's manual ordering
  /// lives in sortOrder and is never touched. Albums the catalog does not
  /// know, including everything from ARD, are left exactly as they are.
  Future<int> reconcileEpisodeNumbers(CatalogService catalog) async {
    // Read and write in one transaction: the pass runs fire-and-forget
    // at app start while the parent may be editing, and a card deleted
    // or removed from its tile between a separate select and the update
    // would get a stale number written back.
    final (changed, scanned) = await _db.transaction(() async {
      final items = await _db.select(_db.cards).get();
      var changed = 0;
      for (final item in items) {
        // tryFromUri skips rows with unexpected URIs instead of
        // aborting the pass at app start.
        final provider = ProviderType.tryFromUri(item.providerUri);
        // Only these two providers have catalog-backed episode numbers.
        if (provider != ProviderType.spotify &&
            provider != ProviderType.appleMusic) {
          continue;
        }
        final albumId = ProviderType.extractId(item.providerUri);
        if (albumId == null) continue;

        final album = catalog.curatedAlbum(albumId, provider: provider!);
        if (album == null) continue; // not curated: nothing authoritative
        if (album.episode == item.episodeNumber) continue;

        // album.episode may be null: the catalog is authoritative even when
        // it assigns no number, so an album reclassified as a compilation
        // clears the stored number and sorts as bonus content instead of
        // keeping a now-stale one.
        await (_db.update(_db.cards)..where((t) => t.id.equals(item.id))).write(
          CardsCompanion(episodeNumber: Value(album.episode)),
        );
        changed++;
      }
      return (changed, items.length);
    });

    if (changed > 0) {
      Log.info(
        _tag,
        'Episode numbers reconciled with the catalog',
        data: {'changed': '$changed', 'scanned': '$scanned'},
      );
    }
    return changed;
  }

  /// Mark an item as unheard.
  Future<void> markUnheard(String itemId) async {
    await (_db.update(_db.cards)..where((t) => t.id.equals(itemId))).write(
      const CardsCompanion(isHeard: Value(false)),
    );
    Log.info(_tag, 'Item marked unheard', data: {'itemId': itemId});
  }

  /// Set ARD fields after an item's initial insert (audio URL, duration,
  /// expiry) along with its tile and episode number. Internal to
  /// [insertArdEpisode], which is the only caller.
  Future<void> _updateArdFields({
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
  /// Combines insertIfAbsent + _updateArdFields atomically — if either
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
        coverUrl: coverUrl,
      );
      await _updateArdFields(
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
          ..orderBy(cardOrder(withEpisodeNumber: false)))
        .get();
  }

  /// Watch ungrouped items (top-level items on kid home).
  Stream<List<TileItem>> watchUngrouped() {
    return (_db.select(_db.cards)
          ..where((t) => t.groupId.isNull())
          ..orderBy(cardOrder(withEpisodeNumber: false)))
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

/// Stream of a single item by ID — emits null if the row is missing.
final tileItemByIdProvider = StreamProvider.family<TileItem?, String>((
  ref,
  itemId,
) {
  return ref.watch(tileItemRepositoryProvider).watchById(itemId);
});

/// Whether the item is confirmed unavailable.
///
/// Only checks the `markedUnavailable` runtime flag, NOT `availableUntil`.
/// ARD's `endDate` (stored as `availableUntil`) is an editorial broadcast
/// window, not content removal. Audio URLs remain on CDN well past endDate.
/// Use `markedUnavailable` for confirmed removal (set on playback failure).
bool isItemExpired(TileItem item) {
  return item.markedUnavailable != null;
}

/// Computes per-tile progress from a list of items.
///
/// Pure function for testability. Excludes expired items and handles
/// playlist track counting. Called by [tileProgressProvider].
Map<String, ({int total, int heard})> computeTileProgress(
  List<TileItem> items,
) {
  final result = <String, ({int total, int heard})>{};
  for (final item in items) {
    final tid = item.groupId;
    if (tid == null) continue;
    // Expired items still register their tile with a zero contribution:
    // a tile whose items are all unavailable keeps a (total: 0) entry,
    // which is how the kid grid tells "broken" from "empty".
    result[tid] ??= (total: 0, heard: 0);
    if (isItemExpired(item)) continue;
    final prev = result[tid]!;
    // For playlists, use the playlist's track count as the display total
    // instead of counting the playlist itself as 1 item. A tile with one
    // 59-track playlist should show "59 Titel", not "1 Folge".
    final itemCount =
        item.cardType == 'playlist' && item.totalTracks > 1
            ? item.totalTracks
            : 1;
    // heard counts in the same unit as total: a finished playlist
    // contributes all its tracks, otherwise the tile's progress bar
    // tops out at 1/trackCount.
    result[tid] = (
      total: prev.total + itemCount,
      heard: prev.heard + (item.isHeard ? itemCount : 0),
    );
  }
  return result;
}

/// Whether a tile's [computeTileProgress] entry means "has items, all
/// confirmed unavailable". The kid grid marks such tiles with a cross
/// instead of hiding them: a tile that silently vanishes confuses kids
/// more than one that is visibly broken.
bool isTileFullyUnavailable(({int total, int heard})? stats) =>
    stats != null && stats.total == 0;

/// Playback progress 0.0–1.0 for a single card, from the stored track
/// position, or from the time position for single-file content (ARD
/// episodes have no track list). Returns 0 for heard or never-started
/// cards.
double albumProgress(TileItem card) {
  if (card.isHeard) return 0;
  if (card.totalTracks > 0 && card.lastTrackNumber > 0) {
    return (card.lastTrackNumber / card.totalTracks).clamp(0.0, 1.0);
  }
  if (card.durationMs > 0 && card.lastPositionMs > 0) {
    return (card.lastPositionMs / card.durationMs).clamp(0.0, 1.0);
  }
  return 0;
}

/// Per-tile item counts and heard progress, derived from allTileItemsProvider.
/// Avoids N+1 queries when rendering the kid home grid.
/// Excludes expired items so kids see accurate episode counts.
final tileProgressProvider = Provider<Map<String, ({int total, int heard})>>(
  (ref) {
    final items = ref.watch(allTileItemsProvider).value ?? [];
    return computeTileProgress(items);
  },
);

/// Set of provider URIs already in the collection.
///
/// Reactive — updates automatically when items are added or removed from
/// any screen. Replaces manual _existingUris bookkeeping in browse screens.
final existingItemUrisProvider = Provider<Set<String>>((ref) {
  final items = ref.watch(allTileItemsProvider).value ?? [];
  return items.map((i) => i.providerUri).toSet();
});

/// Run [TileItemRepository.reconcileEpisodeNumbers] as a fire-and-forget
/// startup pass.
///
/// Failures are logged, never thrown: an error escaping an unawaited
/// call would surface as an unhandled exception at app start, and the
/// pass simply reruns on the next launch. Same contract as
/// runDataMigrations and recheckArdAvailability.
Future<void> reconcileEpisodeNumbersAtStartup({
  required Future<CatalogService> catalog,
  required TileItemRepository items,
}) async {
  try {
    await items.reconcileEpisodeNumbers(await catalog);
    // A TypeError from a catastrophic catalog parse is an Error, not an
    // Exception, and must not escape a fire-and-forget call either.
    // ignore: avoid_catches_without_on_clauses
  } catch (e) {
    Log.error(_tag, 'Episode reconcile failed', exception: e);
  }
}
