import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/ard/ard_api.dart';
import 'package:lauschi/core/database/app_database.dart';
import 'package:lauschi/core/database/data_migrations.dart';
import 'package:lauschi/core/database/tile_item_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/fake_http_adapter.dart';

/// Answers publish date lookups from a fixed table and records each call.
class _FakeArdApi extends ArdApi {
  _FakeArdApi(this.dates);

  final Map<String, DateTime> dates;
  final List<List<String>> calls = [];

  @override
  Future<Map<String, DateTime>> getPublishDates(List<String> itemIds) async {
    calls.add(itemIds);
    return {
      for (final id in itemIds)
        if (dates[id] case final date?) id: date,
    };
  }
}

/// ARD Sounds episodes sort by publish date since schema 15 (#314). The
/// episodes a parent added before get their dates from ARD once.
void main() {
  late AppDatabase db;
  late TileItemRepository items;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase.forTesting(NativeDatabase.memory());
    items = TileItemRepository(db);
  });

  tearDown(() => db.close());

  test('episodes added before get their publish date from ARD', () async {
    final known = <String, DateTime>{};
    for (var i = 0; i < 150; i++) {
      await items.insert(
        title: 'Folge $i',
        providerUri: 'ard:item:$i',
        cardType: 'episode',
      );
      if (i != 7) known['$i'] = DateTime(2025).add(Duration(days: i));
    }
    final album = await items.insert(
      title: 'TKKG 200',
      providerUri: 'spotify:album:tkkg',
      cardType: 'album',
    );
    final api = _FakeArdApi(known);

    await runDataMigrations(DataMigrationContext(items: items, ard: api));

    expect(api.calls.map((c) => c.length), [100, 50]);
    final byUri = {for (final i in await items.getAll()) i.providerUri: i};
    expect(byUri['ard:item:0']!.publishedAt, DateTime(2025));
    expect(byUri['ard:item:149']!.publishedAt, known['149']);
    expect(
      byUri['ard:item:7']!.publishedAt,
      isNull,
      reason: 'ARD no longer lists it, so it keeps no date',
    );
    expect((await items.getById(album))!.publishedAt, isNull);
  });

  // Installs from before the add flow became transactional can hold the
  // same episode twice.
  test('every copy of an episode gets its date', () async {
    for (var copy = 0; copy < 2; copy++) {
      await items.insert(
        title: 'Folge 1',
        providerUri: 'ard:item:1',
        cardType: 'episode',
      );
    }

    await runDataMigrations(
      DataMigrationContext(
        items: items,
        ard: _FakeArdApi({'1': DateTime(2025, 6, 30)}),
      ),
    );

    expect((await items.getAll()).map((i) => i.publishedAt), [
      DateTime(2025, 6, 30),
      DateTime(2025, 6, 30),
    ]);
  });

  test('an answer without items is retried on the next start', () async {
    await items.insert(
      title: 'Folge 1',
      providerUri: 'ard:item:1',
      cardType: 'episode',
    );
    var answer = <String, dynamic>{'data': <String, dynamic>{}};
    final api = ArdApi(adapter: FakeHttpAdapter((_) => answer));

    final lines = <String>[];
    await runZoned(
      () => runDataMigrations(DataMigrationContext(items: items, ard: api)),
      zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, line) => lines.add(line),
      ),
    );
    expect(lines, contains(contains('[DataMigration] Failed')));
    answer = {
      'data': {
        'items': {
          'nodes': [
            {'id': 1, 'publishDate': '2025-06-30T00:00:00+02:00'},
          ],
        },
      },
    };
    await runDataMigrations(DataMigrationContext(items: items, ard: api));

    expect(
      (await items.getAll()).single.publishedAt?.toUtc(),
      DateTime.utc(2025, 6, 29, 22),
    );
  });

  test('a failed lookup is retried on the next start', () async {
    await items.insert(
      title: 'Folge 1',
      providerUri: 'ard:item:1',
      cardType: 'episode',
    );

    final lines = <String>[];
    await runZoned(
      () => runDataMigrations(
        DataMigrationContext(items: items, ard: _OfflineArdApi()),
      ),
      zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, line) => lines.add(line),
      ),
    );
    expect((await items.getAll()).single.publishedAt, isNull);
    expect(
      lines,
      contains(contains('[DataMigration] Offline, retrying next start')),
      reason: 'being offline is no error to report',
    );
    expect(lines, isNot(contains(contains('Failed'))));

    await runDataMigrations(
      DataMigrationContext(
        items: items,
        ard: _FakeArdApi({'1': DateTime(2025, 6, 30)}),
      ),
    );
    expect((await items.getAll()).single.publishedAt, DateTime(2025, 6, 30));
  });
}

class _OfflineArdApi extends ArdApi {
  @override
  Future<Map<String, DateTime>> getPublishDates(List<String> itemIds) =>
      throw const ArdApiException(
        'Keine Internetverbindung',
        isNetworkError: true,
      );
}
