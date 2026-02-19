import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lauschi/core/database/app_database.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:uuid/uuid.dart';

part 'card_repository.g.dart';

const _uuid = Uuid();

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
          ),
        );

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
  }) async {
    await (_db.update(_db.cards)..where((t) => t.id.equals(cardId))).write(
      CardsCompanion(
        lastTrackUri: Value(trackUri),
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
  }

  /// Delete all cards.
  Future<void> deleteAll() async {
    await _db.delete(_db.cards).go();
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
