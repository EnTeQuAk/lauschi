import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:lauschi/core/database/tables.dart';
import 'package:lauschi/core/log.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

part 'app_database.g.dart';

@DriftDatabase(tables: [Cards, Groups, NfcTags, ShowSubscriptions])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  /// Test-only constructor for in-memory databases.
  @visibleForTesting
  AppDatabase.forTesting(super.e);

  /// Bump when schema changes. See [migration] for upgrade steps.
  @override
  int get schemaVersion => 9;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) => m.createAll(),
    onUpgrade: (m, from, to) async {
      Log.info('Database', 'Migrating', data: {'from': '$from', 'to': '$to'});
      try {
        if (from < 2) {
          await m.addColumn(cards, cards.lastTrackUri);
          await m.addColumn(cards, cards.lastPositionMs);
          await m.addColumn(cards, cards.lastPlayedAt);
        }
        if (from < 3) {
          await m.createTable(groups);
          await m.addColumn(cards, cards.groupId);
          await m.addColumn(cards, cards.episodeNumber);
          await m.addColumn(cards, cards.isHeard);
        }
        if (from < 4) {
          await m.addColumn(cards, cards.spotifyArtistIds);
        }
        if (from < 5) {
          await m.addColumn(cards, cards.totalTracks);
          await m.addColumn(cards, cards.lastTrackNumber);
        }
        if (from < 6) {
          await m.addColumn(groups, groups.contentType);
        }
        if (from < 7) {
          await m.createTable(nfcTags);
        }
        if (from < 8) {
          // Multi-provider support: expiration, direct audio, sync.
          await m.addColumn(cards, cards.availableUntil);
          await m.addColumn(cards, cards.audioUrl);
          await m.addColumn(cards, cards.durationMs);
          await m.addColumn(groups, groups.provider);
          await m.addColumn(groups, groups.externalShowId);
          // v8 also added groups.lastSyncedAt — removed in v9 (sync
          // state belongs in ShowSubscriptions). Column stays in SQLite
          // on existing devices but is not referenced by Drift.
          await m.createTable(showSubscriptions);
        }
        if (from < 9) {
          // Removed groups.lastSyncedAt from Dart model — sync state
          // lives exclusively in ShowSubscriptions. No physical column
          // drop needed; SQLite ignores the orphaned column.
        }
        Log.info('Database', 'Migration complete');
      } on Exception catch (e, stack) {
        Log.error(
          'Database',
          'Migration failed',
          data: {'from': '$from', 'to': '$to'},
          exception: e,
        );
        // Report to Sentry so we know about it in production.
        // Don't rethrow — let Drift surface the error to callers.
        await Sentry.captureException(e, stackTrace: stack);
        rethrow;
      }
    },
  );

  static QueryExecutor _openConnection() {
    return driftDatabase(name: 'lauschi');
  }
}

@Riverpod(keepAlive: true)
AppDatabase appDatabase(Ref ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
}
