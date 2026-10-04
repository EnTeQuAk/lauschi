import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lauschi/core/database/app_database.dart';
import 'package:lauschi/core/database/tables.dart' show cardOrder;
import 'package:lauschi/core/database/weiter.dart';
import 'package:lauschi/core/log.dart';

const _tag = 'Listening';

/// The one writer of listening facts: heard, resume point, and the
/// tile's Weiter item.
///
/// Playback calls it at explicit moments (an item counts as started, a
/// resume point is due, an item is finished), and every call is one
/// transaction, so a watching screen never sees half of a change.
class ListeningRepository {
  ListeningRepository(this._db);

  final AppDatabase _db;

  /// [itemId] has played long enough to count as started.
  ///
  /// Its tile now continues with it, and the tile's other items lose
  /// their resume point: a tile works like a CD player with one place to
  /// come back to.
  Future<void> startItem(String itemId) {
    return _db.transaction(() async {
      final item = await _item(itemId);
      final tileId = item?.groupId;
      if (item == null || tileId == null) return;

      await (_db.update(_db.cards)..where(
        (t) => t.groupId.equals(tileId) & t.id.equals(itemId).not(),
      )).write(_noResumePoint);
      await _setWeiter(tileId, itemId, reason: 'started');
    });
  }

  /// Remember where playback of [itemId] stands, so the next play
  /// continues there. [elapsedMs] and [durationMs] cover the whole item
  /// across tracks, a zero [durationMs] keeps the stored duration.
  Future<void> saveResumePoint({
    required String itemId,
    required String trackUri,
    required int trackNumber,
    required int positionMs,
    required int elapsedMs,
    required int durationMs,
  }) async {
    await (_db.update(_db.cards)..where((t) => t.id.equals(itemId))).write(
      CardsCompanion(
        lastTrackUri: Value(trackUri),
        lastTrackNumber: Value(trackNumber),
        lastPositionMs: Value(positionMs),
        lastElapsedMs: Value(elapsedMs),
        durationMs: durationMs > 0 ? Value(durationMs) : const Value.absent(),
        lastPlayedAt: Value(DateTime.now()),
      ),
    );
  }

  /// [itemId] is finished: it counts as heard, the next play starts it
  /// from the beginning, and its tile continues with the item after it.
  Future<void> finishItem(String itemId) {
    return _db.transaction(() async {
      final item = await _item(itemId);
      if (item == null) return;

      await (_db.update(_db.cards)..where(
        (t) => t.id.equals(itemId),
      )).write(_noResumePoint.copyWith(isHeard: const Value(true)));
      Log.info(
        _tag,
        'Item finished',
        data: {'itemId': itemId, 'title': item.title},
      );

      final tileId = item.groupId;
      if (tileId == null) return;
      final next = nextAfter(await _itemsOf(tileId), itemId);
      await _setWeiter(tileId, next?.id, reason: 'finished $itemId');
    });
  }

  /// Forget where playback of [itemId] stood, so it starts from the
  /// beginning.
  Future<void> resetResumePoint(String itemId) async {
    await (_db.update(_db.cards)
      ..where((t) => t.id.equals(itemId))).write(_noResumePoint);
  }

  /// [itemId] is about to leave its tile (moved, removed, deleted).
  ///
  /// When the kid was continuing with it, the tile continues with the
  /// item after it instead of jumping back to the start. Callers run
  /// this inside their own transaction, before the item leaves.
  Future<void> handOverWeiter(String itemId) async {
    final item = await _item(itemId);
    final tileId = item?.groupId;
    if (tileId == null) return;
    final tile =
        await (_db.select(_db.groups)
          ..where((t) => t.id.equals(tileId))).getSingleOrNull();
    if (tile?.weiterItemId != itemId) return;

    final next = nextAfter(await _itemsOf(tileId), itemId);
    // nextAfter wraps around, so a tile's only playable item is its own
    // successor. It is leaving, so nothing is left to continue with.
    await _setWeiter(
      tileId,
      next?.id == itemId ? null : next?.id,
      reason: 'item $itemId left the tile',
    );
  }

  Future<TileItem?> _item(String id) =>
      (_db.select(_db.cards)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<List<TileItem>> _itemsOf(String tileId) =>
      (_db.select(_db.cards)
            ..where((t) => t.groupId.equals(tileId))
            ..orderBy(cardOrder()))
          .get();

  Future<void> _setWeiter(
    String tileId,
    String? itemId, {
    required String reason,
  }) async {
    final tile =
        await (_db.select(_db.groups)
          ..where((t) => t.id.equals(tileId))).getSingleOrNull();
    if (tile == null || tile.weiterItemId == itemId) return;
    await (_db.update(_db.groups)..where(
      (t) => t.id.equals(tileId),
    )).write(GroupsCompanion(weiterItemId: Value(itemId)));
    Log.info(
      _tag,
      'Weiter moved',
      data: {
        'tileId': tileId,
        'from': tile.weiterItemId ?? 'none',
        'to': itemId ?? 'none',
        'reason': reason,
      },
    );
  }
}

const _noResumePoint = CardsCompanion(
  lastTrackUri: Value(null),
  lastTrackNumber: Value(0),
  lastPositionMs: Value(0),
  lastElapsedMs: Value(0),
  lastPlayedAt: Value(null),
);

final listeningRepositoryProvider = Provider<ListeningRepository>((ref) {
  return ListeningRepository(ref.watch(appDatabaseProvider));
});
