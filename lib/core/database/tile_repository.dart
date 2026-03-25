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

  /// Watch root tiles (no parent) ordered by sortOrder.
  /// These are the tiles visible on the kid's home screen.
  Stream<List<Tile>> watchAll() {
    return (_db.select(_db.groups)
          ..where((t) => t.parentTileId.isNull())
          ..orderBy([(t) => OrderingTerm.asc(t.sortOrder)]))
        .watch();
  }

  /// Get root tiles (no parent) ordered by sortOrder.
  Future<List<Tile>> getAll() {
    return (_db.select(_db.groups)
          ..where((t) => t.parentTileId.isNull())
          ..orderBy([(t) => OrderingTerm.asc(t.sortOrder)]))
        .get();
  }

  /// Watch child tiles of a parent, ordered by sortOrder.
  Stream<List<Tile>> watchChildren(String parentId) {
    return (_db.select(_db.groups)
          ..where((t) => t.parentTileId.equals(parentId))
          ..orderBy([(t) => OrderingTerm.asc(t.sortOrder)]))
        .watch();
  }

  /// Get child tiles of a parent, ordered by sortOrder.
  Future<List<Tile>> getChildren(String parentId) {
    return (_db.select(_db.groups)
          ..where((t) => t.parentTileId.equals(parentId))
          ..orderBy([(t) => OrderingTerm.asc(t.sortOrder)]))
        .get();
  }

  /// Whether a tile has any children.
  Future<bool> hasChildren(String tileId) async {
    final count = countAll();
    final query =
        _db.selectOnly(_db.groups)
          ..addColumns([count])
          ..where(_db.groups.parentTileId.equals(tileId));
    final result = await query.getSingle();
    return (result.read(count) ?? 0) > 0;
  }

  /// Get ALL tiles (root + nested), ignoring hierarchy.
  /// Used for lookups that need the full set (e.g. duplicate detection,
  /// URI matching). For display, use [getAll] (root only) or
  /// [getChildren] (one parent's children).
  Future<List<Tile>> getAllFlat() {
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

  /// Move a tile into a parent tile (nest it).
  /// The child tile disappears from the home screen and appears inside
  /// the parent when opened. Throws [ArgumentError] if nesting would
  /// create a cycle (e.g. nesting a parent into its own descendant).
  Future<void> nestInto({
    required String childId,
    required String parentId,
  }) async {
    if (childId == parentId) {
      throw ArgumentError('Cannot nest a tile into itself');
    }
    // Walk up from parentId to root. If we encounter childId,
    // nesting would create a cycle.
    if (await _isDescendantOf(ancestorId: childId, tileId: parentId)) {
      throw ArgumentError(
        'Cannot nest tile $childId into $parentId: would create a cycle',
      );
    }
    // Get the next sort order within the parent
    final maxOrder =
        await _db
            .customSelect(
              'SELECT COALESCE(MAX(sort_order), -1) AS max_order '
              'FROM groups WHERE parent_tile_id = ?',
              variables: [Variable.withString(parentId)],
            )
            .getSingle();
    final nextOrder = (maxOrder.read<int>('max_order')) + 1;

    await (_db.update(_db.groups)..where((t) => t.id.equals(childId))).write(
      GroupsCompanion(
        parentTileId: Value(parentId),
        sortOrder: Value(nextOrder),
      ),
    );
    Log.info(
      _tag,
      'Tile nested',
      data: {'childId': childId, 'parentId': parentId},
    );
  }

  /// Remove a tile from its parent, moving it to the parent's level.
  ///
  /// If the parent folder has 0 remaining children after this, it is
  /// deleted automatically. A folder with 1 child is still valid.
  Future<void> unnest(String tileId) async {
    await _db.transaction(() async {
      // Read the tile to find its parent.
      final tile =
          await (_db.select(_db.groups)
            ..where((t) => t.id.equals(tileId))).getSingle();
      final parentId = tile.parentTileId;

      // Move tile to the parent's level (grandparent, or root).
      String? grandparentId;
      if (parentId != null) {
        final parent =
            await (_db.select(_db.groups)
              ..where((t) => t.id.equals(parentId))).getSingle();
        grandparentId = parent.parentTileId;
      }

      final maxOrder =
          await _db
              .customSelect(
                grandparentId != null
                    ? 'SELECT COALESCE(MAX(sort_order), -1) AS max_order '
                        'FROM groups WHERE parent_tile_id = ?'
                    : 'SELECT COALESCE(MAX(sort_order), -1) AS max_order '
                        'FROM groups WHERE parent_tile_id IS NULL',
                variables: [
                  if (grandparentId != null) Variable.withString(grandparentId),
                ],
              )
              .getSingle();
      final nextOrder = (maxOrder.read<int>('max_order')) + 1;

      await (_db.update(_db.groups)..where((t) => t.id.equals(tileId))).write(
        GroupsCompanion(
          parentTileId: Value(grandparentId),
          sortOrder: Value(nextOrder),
        ),
      );
      Log.info(
        _tag,
        'Tile unnested',
        data: {
          'tileId': tileId,
          'to': grandparentId ?? 'root',
        },
      );

      // Auto-dissolve parent folder if it has ≤1 child left.
      if (parentId != null) {
        await _dissolveIfEmpty(parentId, grandparentId);
      }
    });
  }

  /// Dissolve an empty folder (0 children remaining).
  ///
  /// A folder with 1 child is still valid (like iOS). Only truly
  /// empty folders get cleaned up.
  Future<void> _dissolveIfEmpty(
    String folderId,
    String? parentLevel,
  ) async {
    final childCount =
        await _db
            .customSelect(
              'SELECT COUNT(*) AS cnt FROM groups WHERE parent_tile_id = ?',
              variables: [Variable.withString(folderId)],
            )
            .getSingle();

    if (childCount.read<int>('cnt') > 0) return;

    // Check if this folder has its own content. Don't dissolve those.
    final itemCount =
        await _db
            .customSelect(
              'SELECT COUNT(*) AS cnt FROM cards WHERE group_id = ?',
              variables: [Variable.withString(folderId)],
            )
            .getSingle();
    if (itemCount.read<int>('cnt') > 0) return;

    await (_db.delete(_db.groups)..where((t) => t.id.equals(folderId))).go();
    Log.info(_tag, 'Empty folder deleted', data: {'folderId': folderId});
  }

  /// Create a folder from a drag gesture (tile A dropped onto tile B).
  ///
  /// Creates a new folder tile at B's grid position, then moves both
  /// A and B into it as children. Like iOS home screen folder creation.
  /// Returns the new folder tile ID.
  Future<String> createFolderFromDrag({
    required String draggedId,
    required String targetId,
  }) async {
    late final String folderId;
    await _db.transaction(() async {
      // Read the target tile to inherit its grid position.
      final target =
          await (_db.select(_db.groups)
            ..where((t) => t.id.equals(targetId))).getSingle();

      // Create the folder at the target's position.
      folderId = _uuid.v4();
      await _db
          .into(_db.groups)
          .insert(
            GroupsCompanion.insert(
              id: folderId,
              title: 'Neuer Ordner',
              sortOrder: Value(target.sortOrder),
              parentTileId: Value(target.parentTileId),
            ),
          );

      // Move both tiles into the folder.
      await nestInto(childId: targetId, parentId: folderId);
      await nestInto(childId: draggedId, parentId: folderId);
    });
    Log.info(
      _tag,
      'Folder created from drag',
      data: {
        'folderId': folderId,
        'dragged': draggedId,
        'target': targetId,
      },
    );
    return folderId;
  }

  /// Delete a tile and its entire subtree.
  ///
  /// Items in deleted tiles become ungrouped. NFC tags pointing to
  /// deleted tiles are removed. Children are recursively deleted
  /// (SQLite FK cascade is not enforced; we handle it explicitly).
  Future<void> delete(String id) async {
    await _db.transaction(() async {
      // Collect all tile IDs in the subtree (breadth-first).
      final subtreeIds = <String>[id];
      var queue = [id];
      while (queue.isNotEmpty) {
        final parentIds = queue;
        queue = [];
        for (final pid in parentIds) {
          final children = await getChildren(pid);
          for (final child in children) {
            subtreeIds.add(child.id);
            queue.add(child.id);
          }
        }
      }

      // Unassign all tile items in the subtree.
      for (final tileId in subtreeIds) {
        await (_db.update(_db.cards)..where(
          (t) => t.groupId.equals(tileId),
        )).write(
          const CardsCompanion(
            groupId: Value(null),
            episodeNumber: Value(null),
          ),
        );
      }

      // Remove NFC tags pointing to any tile in the subtree.
      for (final tileId in subtreeIds) {
        await (_db.delete(_db.nfcTags)..where(
          (t) => t.targetId.equals(tileId),
        )).go();
      }

      // Delete all tiles in the subtree (children first, then parent).
      for (final tileId in subtreeIds.reversed) {
        await (_db.delete(_db.groups)..where(
          (t) => t.id.equals(tileId),
        )).go();
      }

      Log.info(
        _tag,
        'Tile deleted',
        data: {'id': id, 'subtreeSize': '${subtreeIds.length}'},
      );
    });
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

  /// Check if [tileId] is a descendant of [ancestorId] by walking up
  /// the parent chain. Used to prevent cycles when nesting.
  Future<bool> _isDescendantOf({
    required String ancestorId,
    required String tileId,
  }) async {
    var currentId = tileId;
    // Safety limit to prevent infinite loops from corrupted data.
    for (var depth = 0; depth < 100; depth++) {
      final tile = await getById(currentId);
      if (tile == null || tile.parentTileId == null) return false;
      if (tile.parentTileId == ancestorId) return true;
      currentId = tile.parentTileId!;
    }
    return false;
  }

  /// Find a tile by title (case-insensitive), searching all tiles
  /// including nested ones.
  ///
  /// Uses Dart-side comparison because SQLite's LOWER() is ASCII-only
  /// and won't handle German umlauts (Ä, Ö, Ü) correctly.
  Future<Tile?> findByTitle(String title) async {
    final normalized = title.trim().toLowerCase();
    final all = await getAllFlat();
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

  /// Get the first unheard, non-expired item in a tile (next episode).
  Future<TileItem?> nextUnheard(String tileId) {
    final now = DateTime.now();
    return (_db.select(_db.cards)
          ..where(
            (t) =>
                t.groupId.equals(tileId) &
                t.isHeard.equals(false) &
                (t.availableUntil.isNull() |
                    t.availableUntil.isBiggerThanValue(now)),
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

/// Stream of root tiles (home screen), ordered by sortOrder.
final allTilesProvider = StreamProvider<List<Tile>>((ref) {
  return ref.watch(tileRepositoryProvider).watchAll();
});

/// Stream of child tiles for a given parent tile.
final childTilesProvider = StreamProvider.family<List<Tile>, String>((
  ref,
  parentId,
) {
  return ref.watch(tileRepositoryProvider).watchChildren(parentId);
});
