import 'package:drift/drift.dart';
import 'package:lauschi/core/database/app_database.dart';
import 'package:lauschi/core/log.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'show_subscription_repository.g.dart';

const _tag = 'ShowSubRepo';

/// CRUD operations for the ShowSubscriptions table.
class ShowSubscriptionRepository {
  ShowSubscriptionRepository(this._db);

  final AppDatabase _db;

  /// Get all subscriptions.
  Future<List<ShowSubscription>> getAll() {
    return _db.select(_db.showSubscriptions).get();
  }

  /// Watch all subscriptions.
  Stream<List<ShowSubscription>> watchAll() {
    return _db.select(_db.showSubscriptions).watch();
  }

  /// Find a subscription by external show ID.
  Future<ShowSubscription?> getByExternalShowId(String externalShowId) {
    return (_db.select(
      _db.showSubscriptions,
    )..where((t) => t.externalShowId.equals(externalShowId))).getSingleOrNull();
  }

  /// Find a subscription by linked group ID.
  Future<ShowSubscription?> getByGroupId(String groupId) {
    return (_db.select(_db.showSubscriptions)
      ..where((t) => t.groupId.equals(groupId))).getSingleOrNull();
  }

  /// Insert a new subscription. Returns the auto-generated ID.
  Future<int> insert({
    required String provider,
    required String externalShowId,
    required String title,
    required String groupId,
    String? coverUrl,
    int? maxEpisodes,
  }) async {
    final id = await _db
        .into(_db.showSubscriptions)
        .insert(
          ShowSubscriptionsCompanion.insert(
            provider: provider,
            externalShowId: externalShowId,
            title: title,
            groupId: groupId,
            coverUrl: Value(coverUrl),
            maxEpisodes: Value(maxEpisodes),
          ),
        );

    Log.info(
      _tag,
      'Subscription created',
      data: {
        'id': '$id',
        'provider': provider,
        'showId': externalShowId,
        'title': title,
      },
    );
    return id;
  }

  /// Update sync state after a successful sync.
  Future<void> updateSyncState({
    required int id,
    required DateTime lastSyncedAt,
    DateTime? remoteLastItemAdded,
  }) async {
    await (_db.update(_db.showSubscriptions)
      ..where((t) => t.id.equals(id))).write(
      ShowSubscriptionsCompanion(
        lastSyncedAt: Value(lastSyncedAt),
        remoteLastItemAdded:
            remoteLastItemAdded != null
                ? Value(remoteLastItemAdded)
                : const Value.absent(),
      ),
    );
  }

  /// Update episode cap.
  Future<void> updateMaxEpisodes({
    required int id,
    int? maxEpisodes,
  }) async {
    await (_db.update(_db.showSubscriptions)
      ..where((t) => t.id.equals(id))).write(
      ShowSubscriptionsCompanion(maxEpisodes: Value(maxEpisodes)),
    );
  }

  /// Delete a subscription by ID.
  Future<void> delete(int id) async {
    await (_db.delete(_db.showSubscriptions)
      ..where((t) => t.id.equals(id))).go();
    Log.info(_tag, 'Subscription deleted', data: {'id': '$id'});
  }
}

@Riverpod(keepAlive: true)
ShowSubscriptionRepository showSubscriptionRepository(Ref ref) {
  return ShowSubscriptionRepository(ref.watch(appDatabaseProvider));
}
