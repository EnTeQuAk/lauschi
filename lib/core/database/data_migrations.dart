import 'dart:async';
import 'dart:math' show min;

import 'package:lauschi/core/ard/ard_api.dart';
import 'package:lauschi/core/database/tile_item_repository.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/providers/provider_type.dart';
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
  const DataMigrationContext({required this.items, required this.ard});

  final TileItemRepository items;
  final ArdApi ard;
}

/// Registry of all data migrations, in order.
///
/// Each entry is (id, migration). IDs are permanent: never rename or remove
/// completed ones. Append new migrations at the end.
final List<(String, DataMigration)> _migrations = [
  ('ard_publish_dates', _backfillArdPublishDates),
];

/// Run all pending data migrations. Safe to call on every startup.
Future<void> runDataMigrations(DataMigrationContext ctx) async {
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
      // Don't mark as done — will retry next launch. Being offline is no
      // error to report.
      if (e is ArdApiException && e.isNetworkError) {
        Log.warn(_tag, 'Offline, retrying next start', data: {'migration': id});
      } else {
        Log.error(_tag, 'Failed', data: {'migration': id}, exception: e);
      }
    }
  }
}

/// ARD Sounds episodes sort by their publish date since schema 15. This
/// fills it in for the episodes added before, [publishDatesBatchSize] per
/// request. An episode ARD no longer lists keeps no date and sorts after
/// the dated ones. A failed request leaves the rest for the next start.
Future<void> _backfillArdPublishDates(DataMigrationContext ctx) async {
  final items = await ctx.items.getArdItemsWithoutPublishDate();
  // Older installs can hold the same episode twice.
  final itemIdsByArdId = <String, List<String>>{};
  for (final item in items) {
    if (ProviderType.extractId(item.providerUri) case final ardId?) {
      (itemIdsByArdId[ardId] ??= []).add(item.id);
    }
  }
  final ardIds = itemIdsByArdId.keys.toList();

  var dated = 0;
  for (var i = 0; i < ardIds.length; i += publishDatesBatchSize) {
    final batch = ardIds.sublist(
      i,
      min(i + publishDatesBatchSize, ardIds.length),
    );
    final dates = await ctx.ard.getPublishDates(batch);
    await ctx.items.setPublishDates({
      for (final MapEntry(key: ardId, value: date) in dates.entries)
        for (final itemId in itemIdsByArdId[ardId] ?? const <String>[])
          itemId: date,
    });
    dated += dates.length;
  }

  Log.info(
    _tag,
    'ARD publish dates filled in',
    data: {'episodes': '${ardIds.length}', 'dated': '$dated'},
  );
}
