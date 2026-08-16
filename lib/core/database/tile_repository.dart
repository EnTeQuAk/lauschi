import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lauschi/core/database/app_database.dart';
import 'package:lauschi/core/database/next_unheard.dart';
import 'package:lauschi/core/database/tables.dart' show cardOrder;
import 'package:lauschi/core/log.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:uuid/uuid.dart';

part 'tile_repository.g.dart';

const _uuid = Uuid();
const _tag = 'TileRepo';

/// A snapshot of the tile/item rows a destructive action removed or moved,
/// with enough state to put them back exactly. [TileRepository.restore]
/// re-inserts deleted rows and resets moved ones. [tiles] are in dependency
/// order: a parent always precedes its children, so restore never dangles a
/// foreign key.
class TileSnapshot {
  const TileSnapshot({
    this.tiles = const [],
    this.items = const [],
    this.nfcTags = const [],
  });

  final List<Tile> tiles;
  final List<TileItem> items;
  final List<NfcTag> nfcTags;

  bool get isEmpty => tiles.isEmpty && items.isEmpty && nfcTags.isEmpty;
}

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
    final nextOrder = await _nextSortOrder();

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
    final nextOrder = await _nextSortOrder(parentId: parentId);

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
  Future<TileSnapshot> unnest(String tileId) {
    return _db.transaction(() async {
      // Read the tile (pre-move) to find its parent.
      final tile =
          await (_db.select(_db.groups)
            ..where((t) => t.id.equals(tileId))).getSingle();
      final parentId = tile.parentTileId;

      // Move tile to the parent's level (grandparent, or root).
      Tile? parent;
      String? grandparentId;
      if (parentId != null) {
        parent =
            await (_db.select(_db.groups)
              ..where((t) => t.id.equals(parentId))).getSingle();
        grandparentId = parent.parentTileId;
      }

      final nextOrder = await _nextSortOrder(parentId: grandparentId);

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

      // Auto-dissolve the parent folder if it now has no children left.
      if (parentId != null) {
        await _dissolveIfEmpty(parentId);
      }

      // Undo re-nests the tile (old parent + sort order); the parent goes
      // first so it's re-created if the dissolve above removed it.
      return TileSnapshot(tiles: [if (parent != null) parent, tile]);
    });
  }

  /// Dissolve an empty folder (0 children remaining).
  ///
  /// A folder with 1 child is still valid (like iOS). Only truly
  /// empty folders get cleaned up.
  Future<void> _dissolveIfEmpty(String folderId) async {
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

  /// Create a new root tile holding the given ungrouped items.
  ///
  /// Triggered when two ungrouped items are merged via drag. The new
  /// tile is appended to the end of root tiles. Its cover is seeded
  /// from the first item that has one, so the result has visible art
  /// before the parent renames it.
  Future<String> createTileFromItems(List<String> itemIds) async {
    if (itemIds.length < 2) {
      throw ArgumentError('createTileFromItems needs at least 2 items');
    }
    late final String tileId;
    await _db.transaction(() async {
      final items =
          await (_db.select(_db.cards)..where((t) => t.id.isIn(itemIds))).get();
      final byId = {for (final i in items) i.id: i};
      final seedCover =
          itemIds
              .map((id) => byId[id]?.coverUrl)
              .whereType<String>()
              .firstOrNull;

      final nextOrder = await _nextSortOrder();

      tileId = _uuid.v4();
      await _db
          .into(_db.groups)
          .insert(
            GroupsCompanion.insert(
              id: tileId,
              title: 'Neue Kachel',
              sortOrder: Value(nextOrder),
              coverUrl: Value(seedCover),
            ),
          );

      // Assign each item to the new tile. Preserve the dragged-first
      // order so episode numbering reflects the merge gesture.
      for (var i = 0; i < itemIds.length; i++) {
        await (_db.update(_db.cards)..where(
          (t) => t.id.equals(itemIds[i]),
        )).write(
          CardsCompanion(
            groupId: Value(tileId),
            sortOrder: Value(i),
          ),
        );
      }
    });
    Log.info(
      _tag,
      'Tile created from items',
      data: {'tileId': tileId, 'itemCount': '${itemIds.length}'},
    );
    return tileId;
  }

  /// Merge a tile and an ungrouped item into a new folder.
  ///
  /// Triggered when a tile is dragged onto an ungrouped item (or vice
  /// versa). The folder takes [tileId]'s grid position, nests the tile
  /// inside, and assigns the item directly to the folder.
  Future<String> createTileFromTileAndItem({
    required String tileId,
    required String itemId,
  }) async {
    late final String folderId;
    await _db.transaction(() async {
      final tile =
          await (_db.select(_db.groups)
            ..where((t) => t.id.equals(tileId))).getSingle();

      folderId = _uuid.v4();
      await _db
          .into(_db.groups)
          .insert(
            GroupsCompanion.insert(
              id: folderId,
              title: 'Neuer Ordner',
              sortOrder: Value(tile.sortOrder),
              parentTileId: Value(tile.parentTileId),
            ),
          );

      // Tile becomes a child of the folder.
      await nestInto(childId: tileId, parentId: folderId);

      // Item is assigned directly to the folder.
      await (_db.update(_db.cards)..where((t) => t.id.equals(itemId))).write(
        CardsCompanion(groupId: Value(folderId)),
      );
    });
    Log.info(
      _tag,
      'Folder created from tile + item',
      data: {
        'folderId': folderId,
        'tile': tileId,
        'item': itemId,
      },
    );
    return folderId;
  }

  /// Delete a tile and its entire subtree.
  ///
  /// Items in deleted tiles become ungrouped. NFC tags pointing to
  /// deleted tiles are removed. Children are recursively deleted
  /// (SQLite FK cascade is not enforced; we handle it explicitly).
  Future<TileSnapshot> delete(String id) {
    return _db.transaction(() async {
      // Collect all tile IDs in the subtree, breadth-first so parents
      // precede their children (the order restore needs).
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

      // Snapshot everything for undo before touching it: the tiles
      // (parents-first), their items, and their NFC tags.
      final tiles = <Tile>[];
      for (final tileId in subtreeIds) {
        final tile =
            await (_db.select(_db.groups)
              ..where((t) => t.id.equals(tileId))).getSingleOrNull();
        if (tile != null) tiles.add(tile);
      }
      final items =
          await (_db.select(_db.cards)
            ..where((t) => t.groupId.isIn(subtreeIds))).get();
      final nfcTags =
          await (_db.select(_db.nfcTags)
            ..where((t) => t.targetId.isIn(subtreeIds))).get();

      // Delete the items, then the NFC tags, then the tiles (children
      // first so no child dangles off a deleted parent).
      await (_db.delete(_db.cards)
        ..where((t) => t.groupId.isIn(subtreeIds))).go();
      await (_db.delete(_db.nfcTags)
        ..where((t) => t.targetId.isIn(subtreeIds))).go();
      for (final tileId in subtreeIds.reversed) {
        await (_db.delete(_db.groups)..where((t) => t.id.equals(tileId))).go();
      }

      Log.info(
        _tag,
        'Tile deleted',
        data: {
          'id': id,
          'subtreeSize': '${subtreeIds.length}',
          'items': '${items.length}',
        },
      );
      return TileSnapshot(tiles: tiles, items: items, nfcTags: nfcTags);
    });
  }

  /// Puts back the rows captured in [snapshot], undoing a prior destructive
  /// action. Runs in one transaction so a restore is all-or-nothing: tiles
  /// first (parents before children), then items, then NFC tags, so every
  /// foreign key resolves. Re-inserts deleted rows and resets moved ones.
  Future<void> restore(TileSnapshot snapshot) async {
    if (snapshot.isEmpty) return;
    await _db.transaction(() async {
      for (final tile in snapshot.tiles) {
        await _db.into(_db.groups).insertOnConflictUpdate(tile);
      }
      for (final item in snapshot.items) {
        await _db.into(_db.cards).insertOnConflictUpdate(item);
      }
      for (final tag in snapshot.nfcTags) {
        await _db.into(_db.nfcTags).insertOnConflictUpdate(tag);
      }
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

  /// Next free sort order for a new tile at a given level: one past the
  /// current max among its siblings. [parentId] null scopes to the root
  /// level (parent_tile_id IS NULL); non-null scopes to that parent's
  /// children.
  Future<int> _nextSortOrder({String? parentId}) async {
    final row =
        await _db
            .customSelect(
              parentId != null
                  ? 'SELECT COALESCE(MAX(sort_order), -1) AS max_order '
                      'FROM groups WHERE parent_tile_id = ?'
                  : 'SELECT COALESCE(MAX(sort_order), -1) AS max_order '
                      'FROM groups WHERE parent_tile_id IS NULL',
              variables: [
                if (parentId != null) Variable.withString(parentId),
              ],
            )
            .getSingle();
    return row.read<int>('max_order') + 1;
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

  /// Find a tile by title, or create one if none exists.
  ///
  /// Runs in a transaction so concurrent adds of the same series don't
  /// each pass the existence check and create duplicate groups. The
  /// catalog add buttons fire fire-and-forget, so double-taps race here
  /// the same way they do on TileItemRepository.insertIfAbsent.
  Future<String> findOrCreateByTitle(String title) {
    return _db.transaction(() async {
      final existing = await findByTitle(title);
      if (existing != null) return existing.id;
      return insert(title: title);
    });
  }

  /// Watch items belonging to a tile.
  /// Sort: manual order (sortOrder) if set, otherwise episodeNumber, then
  /// creation time as tiebreaker for items with neither.
  Stream<List<TileItem>> watchItems(String tileId) {
    return (_db.select(_db.cards)
          ..where((t) => t.groupId.equals(tileId))
          ..orderBy(cardOrder()))
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

  /// Get the next episode to play in a tile.
  ///
  /// Priority:
  /// 1. In-progress episode (has saved position, not heard)
  /// 2. First unheard episode after the last heard one in sort order
  /// 3. First unheard episode overall (nothing heard yet)
  ///
  /// Skips items confirmed unavailable via markedUnavailable flag.
  Future<TileItem?> nextUnheard(String tileId) async {
    final episodes =
        await (_db.select(_db.cards)
              ..where((t) => t.groupId.equals(tileId))
              ..orderBy(cardOrder()))
            .get();

    return pickNextUnheard(
      episodes,
      isAvailable: (ep) => !ep.isHeard && ep.markedUnavailable == null,
    );
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

/// The tile metadata for a given ID, reactive to DB changes.
final tileByIdProvider = StreamProvider.family<Tile?, String>((ref, tileId) {
  return ref.watch(tileRepositoryProvider).watchById(tileId);
});

/// The items (episodes) belonging to a tile, ordered, reactive to DB changes.
final tileItemsProvider = StreamProvider.family<List<TileItem>, String>((
  ref,
  tileId,
) {
  return ref.watch(tileRepositoryProvider).watchItems(tileId);
});

/// Stream of child tiles for a given parent tile.
final childTilesProvider = StreamProvider.family<List<Tile>, String>((
  ref,
  parentId,
) {
  return ref.watch(tileRepositoryProvider).watchChildren(parentId);
});
