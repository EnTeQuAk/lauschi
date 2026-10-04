import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:lauschi/core/database/app_database.steps.dart';
import 'package:lauschi/core/database/tables.dart';
import 'package:lauschi/core/database/weiter_backfill.dart';
import 'package:lauschi/core/log.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

part 'app_database.g.dart';

@DriftDatabase(tables: [Cards, Groups, NfcTags, ShowSubscriptions])
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? e]) : super(e ?? _openConnection());

  /// Test-only constructor for in-memory databases.
  @visibleForTesting
  AppDatabase.forTesting(super.e);

  /// Bump when schema changes. See [migration] for upgrade steps.
  @override
  int get schemaVersion => 14;

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
        if (from < 10) {
          // Tile nesting: parent_tile_id enables grouping tiles inside
          // other tiles (e.g. all Senta albums under a "Senta" tile).
          // Self-referencing FK, nullable (null = root tile on home screen).
          await m.addColumn(groups, groups.parentTileId);
          // Index for fast root-tile queries (WHERE parent_tile_id IS NULL)
          // and child lookups (WHERE parent_tile_id = ?).
          await customStatement(
            'CREATE INDEX IF NOT EXISTS idx_groups_parent_tile_id '
            'ON groups(parent_tile_id)',
          );
        }
        if (from < 11) {
          // Content expiration: records when an item became unavailable.
          // Null = available. Non-null = unavailable since that date.
          await m.addColumn(cards, cards.markedUnavailable);
        }
        if (from < 12) {
          // Indexes for the two most frequent card lookups:
          // - groupId: watchItems, itemCount, nextUnheard (per-tile queries)
          // - providerUri: insertIfAbsent deduplication, getByProviderUri
          await customStatement(
            'CREATE INDEX IF NOT EXISTS idx_cards_group_id '
            'ON cards(group_id)',
          );
          await customStatement(
            'CREATE INDEX IF NOT EXISTS idx_cards_provider_uri '
            'ON cards(provider_uri)',
          );
        }
        if (from < 13 && to >= 13) {
          // Make sort_order nullable on cards. NULL = auto-sort by
          // episode_number. Non-null = parent manually ordered.
          // SQLite can't ALTER COLUMN constraints, so we rebuild
          // the table via Drift's TableMigration, which creates a
          // new table with the correct schema, copies data, and
          // swaps. All existing sort_order values become NULL.
          //
          // Guard includes `to >= 13` because TableMigration recreates
          // the table from the current Dart schema (nullable sort_order).
          // Without the upper bound, migrating to v11/v12 in tests would
          // incorrectly apply v13's schema.
          //
          // The rebuild uses the cards table as it was at v13, not the
          // current Dart schema: copying today's columns would read ones
          // (like v14's last_elapsed_ms) that don't exist yet at this step.
          final v13Cards = Schema13(database: this).cards;
          await m.alterTable(
            TableMigration(
              v13Cards,
              columnTransformer: {v13Cards.sortOrder: const Constant(null)},
            ),
          );
        }
        // Upper bound for the same reason as v13: tests migrate to older
        // versions, and the columns added here belong to v14 only.
        if (from < 14 && to >= 14) {
          // The Weiter item becomes a stored fact instead of being
          // derived on every read, and the resume point records how far
          // into the whole item it is.
          await m.addColumn(groups, groups.weiterItemId);
          await m.addColumn(cards, cards.lastElapsedMs);
          await _backfillWeiter();
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

  /// Store, for every tile, the Weiter item the app derived before
  /// schema 14, so the badge stays where the kid left it.
  Future<void> _backfillWeiter() async {
    final now = DateTime.now();
    final tiles = await select(groups).get();
    for (final tile in tiles) {
      final items =
          await (select(cards)
                ..where((t) => t.groupId.equals(tile.id))
                ..orderBy(cardOrder()))
              .get();
      final weiter = legacyWeiterFor(items, now: now);
      if (weiter == null) continue;
      await (update(groups)..where(
        (t) => t.id.equals(tile.id),
      )).write(GroupsCompanion(weiterItemId: Value(weiter.id)));
    }
  }

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
