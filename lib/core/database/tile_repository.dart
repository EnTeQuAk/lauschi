import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lauschi/core/database/app_database.dart';
import 'package:lauschi/core/log.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:uuid/uuid.dart';

part 'tile_repository.g.dart';

const _uuid = Uuid();
const _tag = 'TileRepo';

/// CRUD operations for tiles (DB table: `groups`).
class TileRepository {
  TileRepository(this._db);

  final AppDatabase _db;

  /// Watch all tiles ordered by sortOrder.
  Stream<List<Tile>> watchAll() {
    return (_db.select(_db.groups)
      ..orderBy([(t) => OrderingTerm.asc(t.sortOrder)])).watch();
  }

  /// Get all tiles ordered by sortOrder.
  Future<List<Tile>> getAll() {
    return (_db.select(_db.groups)
      ..orderBy([(t) => OrderingTerm.asc(t.sortOrder)])).get();
  }

  /// Get a single tile by ID.
  Future<Tile?> getById(String id) {
    return (_db.select(_db.groups)
      ..where((t) => t.id.equals(id))).getSingleOrNull();
  }

  /// Watch a single tile by ID. Emits null if not found.
  Stream<Tile?> watchById(String id) {
    return (_db.select(_db.groups)
      ..where((t) => t.id.equals(id))).watchSingleOrNull();
  }

  /// Insert a new tile. Returns the generated ID.
  Future<String> insert({
    required String title,
    String? coverUrl,
    String contentType = 'hoerspiel',
  }) async {
    final trimmedTitle = title.trim();
    final id = _uuid.v4();

    final maxOrder =
        await _db
            .customSelect(
              'SELECT COALESCE(MAX(sort_order), -1) AS max_order FROM groups',
            )
            .getSingle();
    final nextOrder = (maxOrder.read<int>('max_order')) + 1;

    await _db
        .into(_db.groups)
        .insert(
          GroupsCompanion.insert(
            id: id,
            title: trimmedTitle,
            coverUrl: Value(coverUrl),
            sortOrder: Value(nextOrder),
            contentType: Value(contentType),
          ),
        );

    Log.info(
      _tag,
      'Tile created',
      data: {'id': id, 'title': title, 'contentType': contentType},
    );
    return id;
  }

  /// Update a tile's title, cover, and/or content type.
  Future<void> update({
    required String id,
    String? title,
    String? coverUrl,
    bool clearCoverUrl = false,
    String? contentType,
  }) async {
    await (_db.update(_db.groups)..where((t) => t.id.equals(id))).write(
      GroupsCompanion(
        title: title != null ? Value(title) : const Value.absent(),
        coverUrl:
            clearCoverUrl
                ? const Value(null)
                : coverUrl != null
                ? Value(coverUrl)
                : const Value.absent(),
        contentType:
            contentType != null ? Value(contentType) : const Value.absent(),
      ),
    );
    Log.info(
      _tag,
      'Tile updated',
      data: {
        'id': id,
        if (title != null) 'title': title,
        'coverOp':
            clearCoverUrl ? 'clear' : (coverUrl != null ? 'set' : 'none'),
      },
    );
  }

  /// Delete a tile. Items in the tile become ungrouped.
  Future<void> delete(String id) async {
    // Unassign all items first
    await (_db.update(_db.cards)..where((t) => t.groupId.equals(id))).write(
      const CardsCompanion(
        groupId: Value(null),
        episodeNumber: Value(null),
      ),
    );
    await (_db.delete(_db.groups)..where((t) => t.id.equals(id))).go();
    Log.info(_tag, 'Tile deleted', data: {'id': id});
  }

  /// Reorder tiles.
  Future<void> reorder(List<String> idsInOrder) async {
    await _db.transaction(() async {
      for (var i = 0; i < idsInOrder.length; i++) {
        await (_db.update(_db.groups)..where(
          (t) => t.id.equals(idsInOrder[i]),
        )).write(GroupsCompanion(sortOrder: Value(i)));
      }
    });
  }

  /// Find a tile by title (case-insensitive).
  ///
  /// Uses Dart-side comparison because SQLite's LOWER() is ASCII-only
  /// and won't handle German umlauts (Ä, Ö, Ü) correctly.
  Future<Tile?> findByTitle(String title) async {
    final normalized = title.trim().toLowerCase();
    final all = await getAll();
    return all
        .where((t) => t.title.trim().toLowerCase() == normalized)
        .firstOrNull;
  }

  /// Watch items belonging to a tile, ordered by episodeNumber then sortOrder.
  Stream<List<TileItem>> watchItems(String tileId) {
    return (_db.select(_db.cards)
          ..where((t) => t.groupId.equals(tileId))
          ..orderBy([
            (t) => OrderingTerm.asc(t.episodeNumber),
            (t) => OrderingTerm.asc(t.sortOrder),
          ]))
        .watch();
  }

  /// Get the number of items in a tile.
  Future<int> itemCount(String tileId) async {
    final count = countAll();
    final query =
        _db.selectOnly(_db.cards)
          ..addColumns([count])
          ..where(_db.cards.groupId.equals(tileId));
    final result = await query.getSingle();
    return result.read(count) ?? 0;
  }

  /// Get the first unheard item in a tile (next episode).
  Future<TileItem?> nextUnheard(String tileId) {
    return (_db.select(_db.cards)
          ..where(
            (t) => t.groupId.equals(tileId) & t.isHeard.equals(false),
          )
          ..orderBy([
            (t) => OrderingTerm.asc(t.episodeNumber),
            (t) => OrderingTerm.asc(t.sortOrder),
          ])
          ..limit(1))
        .getSingleOrNull();
  }
}

@Riverpod(keepAlive: true)
TileRepository tileRepository(Ref ref) {
  return TileRepository(ref.watch(appDatabaseProvider));
}

/// Stream of all tiles, ordered by sortOrder.
final allTilesProvider = StreamProvider<List<Tile>>((ref) {
  return ref.watch(tileRepositoryProvider).watchAll();
});
