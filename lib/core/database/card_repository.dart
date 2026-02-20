import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lauschi/core/database/app_database.dart';
import 'package:lauschi/core/log.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:uuid/uuid.dart';

part 'card_repository.g.dart';

const _uuid = Uuid();
const _tag = 'CardRepo';

/// CRUD operations for the Cards table.
class CardRepository {
  CardRepository(this._db);

  final AppDatabase _db;

  /// Watch all cards ordered by sortOrder.
  Stream<List<AudioCard>> watchAll() {
    return (_db.select(_db.cards)
      ..orderBy([(t) => OrderingTerm.asc(t.sortOrder)])).watch();
  }

  /// Get all cards ordered by sortOrder.
  Future<List<AudioCard>> getAll() {
    return (_db.select(_db.cards)
      ..orderBy([(t) => OrderingTerm.asc(t.sortOrder)])).get();
  }

  /// Get a single card by ID.
  Future<AudioCard?> getById(String id) {
    return (_db.select(_db.cards)
      ..where((t) => t.id.equals(id))).getSingleOrNull();
  }

  /// Insert a new card. Returns the generated ID.
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

    Log.info(_tag, 'Card added', data: {'title': title, 'provider': provider});
    return id;
  }

  /// Insert a card only if the providerUri doesn't already exist.
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

  /// Update sort order for multiple cards.
  Future<void> reorder(List<String> idsInOrder) async {
    await _db.transaction(() async {
      for (var i = 0; i < idsInOrder.length; i++) {
        await (_db.update(_db.cards)..where(
          (t) => t.id.equals(idsInOrder[i]),
        )).write(CardsCompanion(sortOrder: Value(i)));
      }
    });
  }

  /// Save playback position for a card.
  Future<void> savePosition({
    required String cardId,
    required String trackUri,
    required int positionMs,
    int trackNumber = 0,
  }) async {
    await (_db.update(_db.cards)..where((t) => t.id.equals(cardId))).write(
      CardsCompanion(
        lastTrackUri: Value(trackUri),
        lastTrackNumber: Value(trackNumber),
        lastPositionMs: Value(positionMs),
        lastPlayedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Get the most recently played card (for resume on app launch).
  Future<AudioCard?> lastPlayed() {
    return (_db.select(_db.cards)
          ..where((t) => t.lastPlayedAt.isNotNull())
          ..orderBy([(t) => OrderingTerm.desc(t.lastPlayedAt)])
          ..limit(1))
        .getSingleOrNull();
  }

  /// Find a card by its provider URI.
  Future<AudioCard?> getByProviderUri(String uri) {
    return (_db.select(_db.cards)
      ..where((t) => t.providerUri.equals(uri))).getSingleOrNull();
  }

  /// Delete a card by ID.
  Future<void> delete(String id) async {
    await (_db.delete(_db.cards)..where((t) => t.id.equals(id))).go();
    Log.info(_tag, 'Card deleted', data: {'cardId': id});
  }

  /// Delete all cards.
  Future<void> deleteAll() async {
    await _db.delete(_db.cards).go();
  }

  /// Delete all cards in a group.
  Future<int> deleteByGroup(String groupId) async {
    final count =
        await (_db.delete(_db.cards)
              ..where((t) => t.groupId.equals(groupId)))
            .go();
    Log.info(
      _tag,
      'Deleted cards by group',
      data: {'groupId': groupId, 'count': '$count'},
    );
    return count;
  }

  /// Assign a card to a group with optional episode number.
  Future<void> assignToGroup({
    required String cardId,
    required String groupId,
    int? episodeNumber,
  }) async {
    await (_db.update(_db.cards)..where((t) => t.id.equals(cardId))).write(
      CardsCompanion(
        groupId: Value(groupId),
        episodeNumber: Value(episodeNumber),
      ),
    );
    Log.info(
      _tag,
      'Card assigned to group',
      data: {
        'cardId': cardId,
        'groupId': groupId,
        if (episodeNumber != null) 'episode': episodeNumber,
      },
    );
  }

  /// Remove a card from its group.
  Future<void> removeFromGroup(String cardId) async {
    await (_db.update(_db.cards)..where((t) => t.id.equals(cardId))).write(
      const CardsCompanion(
        groupId: Value(null),
        episodeNumber: Value(null),
      ),
    );
  }

  /// Mark a card as heard.
  Future<void> markHeard(String cardId) async {
    await (_db.update(_db.cards)..where((t) => t.id.equals(cardId))).write(
      const CardsCompanion(isHeard: Value(true)),
    );
    Log.info(_tag, 'Card marked heard', data: {'cardId': cardId});
  }

  /// Mark a card as unheard.
  Future<void> markUnheard(String cardId) async {
    await (_db.update(_db.cards)..where((t) => t.id.equals(cardId))).write(
      const CardsCompanion(isHeard: Value(false)),
    );
  }

  /// Set totalTracks for a card (used by data migration backfill).
  Future<void> updateTotalTracks({
    required String cardId,
    required int totalTracks,
  }) async {
    await (_db.update(_db.cards)..where((t) => t.id.equals(cardId))).write(
      CardsCompanion(totalTracks: Value(totalTracks)),
    );
  }

  /// Get ungrouped cards as a one-shot fetch.
  Future<List<AudioCard>> getUngrouped() {
    return (_db.select(_db.cards)
          ..where((t) => t.groupId.isNull())
          ..orderBy([(t) => OrderingTerm.asc(t.sortOrder)]))
        .get();
  }

  /// Watch ungrouped cards (top-level items on kid home).
  Stream<List<AudioCard>> watchUngrouped() {
    return (_db.select(_db.cards)
          ..where((t) => t.groupId.isNull())
          ..orderBy([(t) => OrderingTerm.asc(t.sortOrder)]))
        .watch();
  }
}

@Riverpod(keepAlive: true)
CardRepository cardRepository(Ref ref) {
  return CardRepository(ref.watch(appDatabaseProvider));
}

/// Stream of all cards, ordered by sortOrder.
///
/// Manual provider (not generated) because the Drift-generated AudioCard
/// type can't be resolved by riverpod_generator at codegen time.
final allCardsProvider = StreamProvider<List<AudioCard>>((ref) {
  return ref.watch(cardRepositoryProvider).watchAll();
});

/// Stream of ungrouped cards (top-level, not in any series).
final ungroupedCardsProvider = StreamProvider<List<AudioCard>>((ref) {
  return ref.watch(cardRepositoryProvider).watchUngrouped();
});

/// Per-group card counts and heard progress, derived from allCardsProvider.
/// Avoids N+1 queries when rendering the kid home grid.
final groupProgressProvider =
    Provider<Map<String, ({int total, int heard})>>((ref) {
  final cards = ref.watch(allCardsProvider).value ?? [];
  final result = <String, ({int total, int heard})>{};
  for (final card in cards) {
    final gid = card.groupId;
    if (gid == null) continue;
    final prev = result[gid] ?? (total: 0, heard: 0);
    result[gid] = (
      total: prev.total + 1,
      heard: prev.heard + (card.isHeard ? 1 : 0),
    );
  }
  return result;
});
