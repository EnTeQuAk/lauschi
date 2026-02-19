import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lauschi/core/database/app_database.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:uuid/uuid.dart';

part 'group_repository.g.dart';

const _uuid = Uuid();

/// CRUD operations for the Groups table.
class GroupRepository {
  GroupRepository(this._db);

  final AppDatabase _db;

  /// Watch all groups ordered by sortOrder.
  Stream<List<CardGroup>> watchAll() {
    return (_db.select(_db.groups)
      ..orderBy([(t) => OrderingTerm.asc(t.sortOrder)])).watch();
  }

  /// Get all groups ordered by sortOrder.
  Future<List<CardGroup>> getAll() {
    return (_db.select(_db.groups)
      ..orderBy([(t) => OrderingTerm.asc(t.sortOrder)])).get();
  }

  /// Get a single group by ID.
  Future<CardGroup?> getById(String id) {
    return (_db.select(_db.groups)
      ..where((t) => t.id.equals(id))).getSingleOrNull();
  }

  /// Insert a new group. Returns the generated ID.
  Future<String> insert({
    required String title,
    String? coverUrl,
  }) async {
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
            title: title,
            coverUrl: Value(coverUrl),
            sortOrder: Value(nextOrder),
          ),
        );

    return id;
  }

  /// Update a group's title and/or cover.
  Future<void> update({
    required String id,
    String? title,
    String? coverUrl,
    bool clearCoverUrl = false,
  }) async {
    await (_db.update(_db.groups)..where((t) => t.id.equals(id))).write(
      GroupsCompanion(
        title: title != null ? Value(title) : const Value.absent(),
        coverUrl: clearCoverUrl
            ? const Value(null)
            : coverUrl != null
                ? Value(coverUrl)
                : const Value.absent(),
      ),
    );
  }

  /// Delete a group. Cards in the group become ungrouped.
  Future<void> delete(String id) async {
    // Unassign all cards first
    await (_db.update(_db.cards)..where((t) => t.groupId.equals(id))).write(
      const CardsCompanion(
        groupId: Value(null),
        episodeNumber: Value(null),
      ),
    );
    await (_db.delete(_db.groups)..where((t) => t.id.equals(id))).go();
  }

  /// Reorder groups.
  Future<void> reorder(List<String> idsInOrder) async {
    await _db.transaction(() async {
      for (var i = 0; i < idsInOrder.length; i++) {
        await (_db.update(_db.groups)..where(
          (t) => t.id.equals(idsInOrder[i]),
        )).write(GroupsCompanion(sortOrder: Value(i)));
      }
    });
  }

  /// Watch cards belonging to a group, ordered by episodeNumber then sortOrder.
  Stream<List<AudioCard>> watchCards(String groupId) {
    return (_db.select(_db.cards)
      ..where((t) => t.groupId.equals(groupId))
      ..orderBy([
        (t) => OrderingTerm.asc(t.episodeNumber),
        (t) => OrderingTerm.asc(t.sortOrder),
      ])).watch();
  }

  /// Get the number of cards in a group.
  Future<int> cardCount(String groupId) async {
    final count = countAll();
    final query = _db.selectOnly(_db.cards)
      ..addColumns([count])
      ..where(_db.cards.groupId.equals(groupId));
    final result = await query.getSingle();
    return result.read(count) ?? 0;
  }

  /// Get the first unheard card in a group (next episode).
  Future<AudioCard?> nextUnheard(String groupId) {
    return (_db.select(_db.cards)
      ..where(
        (t) => t.groupId.equals(groupId) & t.isHeard.equals(false),
      )
      ..orderBy([
        (t) => OrderingTerm.asc(t.episodeNumber),
        (t) => OrderingTerm.asc(t.sortOrder),
      ])
      ..limit(1)).getSingleOrNull();
  }
}

@Riverpod(keepAlive: true)
GroupRepository groupRepository(Ref ref) {
  return GroupRepository(ref.watch(appDatabaseProvider));
}

/// Stream of all groups, ordered by sortOrder.
final allGroupsProvider = StreamProvider<List<CardGroup>>((ref) {
  return ref.watch(groupRepositoryProvider).watchAll();
});
