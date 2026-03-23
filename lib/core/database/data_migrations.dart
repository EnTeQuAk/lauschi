import 'dart:async';

import 'package:lauschi/core/database/tile_item_repository.dart';
import 'package:lauschi/core/log.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _tag = 'DataMigration';
const _prefsPrefix = 'data_migration_done_';

/// A named data migration that runs once at app startup.
///
/// Unlike schema migrations (Drift's onUpgrade), these run after services
/// are initialized and can make API calls, read settings, etc.
typedef DataMigration = Future<void> Function(DataMigrationContext ctx);

/// Context passed to each migration. Extend with additional services
/// as needed when adding new migrations.
class DataMigrationContext {
  const DataMigrationContext({
    required this.items,
  });

  final TileItemRepository items;
}

/// Registry of all data migrations, in order.
///
/// Each entry is (id, migration). IDs are permanent: never rename or remove
/// completed ones. Append new migrations at the end.
final List<(String, DataMigration)> _migrations = [];

/// Run all pending data migrations. Safe to call on every startup.
Future<void> runDataMigrations(DataMigrationContext ctx) async {
  if (_migrations.isEmpty) return;

  final prefs = await SharedPreferences.getInstance();

  for (final (id, migrate) in _migrations) {
    final key = '$_prefsPrefix$id';
    if (prefs.getBool(key) ?? false) continue;

    Log.info(_tag, 'Running', data: {'migration': id});
    try {
      await migrate(ctx);
      await prefs.setBool(key, true);
      Log.info(_tag, 'Complete', data: {'migration': id});
    } on Exception catch (e) {
      // Don't mark as done — will retry next launch.
      Log.error(_tag, 'Failed', data: {'migration': id}, exception: e);
    }
  }
}
