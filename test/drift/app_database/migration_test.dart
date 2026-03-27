// dart format width=80
import 'package:drift/drift.dart';
import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/database/app_database.dart';

import 'generated/schema.dart';
import 'generated/schema_v10.dart' as v10;
import 'generated/schema_v11.dart' as v11;

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late SchemaVerifier verifier;

  setUpAll(() {
    verifier = SchemaVerifier(GeneratedHelper());
  });

  group('simple database migrations', () {
    // These simple tests verify all possible schema updates with a simple (no
    // data) migration. This is a quick way to ensure that written database
    // migrations properly alter the schema.
    const versions = GeneratedHelper.versions;
    for (final (i, fromVersion) in versions.indexed) {
      group('from $fromVersion', () {
        for (final toVersion in versions.skip(i + 1)) {
          test('to $toVersion', () async {
            final schema = await verifier.schemaAt(fromVersion);
            final db = AppDatabase(schema.newConnection());
            await verifier.migrateAndValidate(db, toVersion);
            await db.close();
          });
        }
      });
    }
  });

  // The following template shows how to write tests ensuring your migrations
  // preserve existing data.
  // Testing this can be useful for migrations that change existing columns
  // (e.g. by alterating their type or constraints). Migrations that only add
  // tables or columns typically don't need these advanced tests. For more
  // information, see https://drift.simonbinder.eu/migrations/tests/#verifying-data-integrity
  // TODO: This generated template shows how these tests could be written. Adopt
  // it to your own needs when testing migrations with data integrity.
  test('migration from v10 to v11 does not corrupt data', () async {
    // Add data to insert into the old database, and the expected rows after the
    // migration.
    // TODO: Fill these lists
    final oldGroupsData = <v10.GroupsData>[];
    final expectedNewGroupsData = <v11.GroupsData>[];

    final oldCardsData = <v10.CardsData>[];
    final expectedNewCardsData = <v11.CardsData>[];

    final oldNfcTagsData = <v10.NfcTagsData>[];
    final expectedNewNfcTagsData = <v11.NfcTagsData>[];

    final oldShowSubscriptionsData = <v10.ShowSubscriptionsData>[];
    final expectedNewShowSubscriptionsData = <v11.ShowSubscriptionsData>[];

    await verifier.testWithDataIntegrity(
      oldVersion: 10,
      newVersion: 11,
      createOld: v10.DatabaseAtV10.new,
      createNew: v11.DatabaseAtV11.new,
      openTestedDatabase: AppDatabase.new,
      createItems: (batch, oldDb) {
        batch
          ..insertAll(oldDb.groups, oldGroupsData)
          ..insertAll(oldDb.cards, oldCardsData)
          ..insertAll(oldDb.nfcTags, oldNfcTagsData)
          ..insertAll(oldDb.showSubscriptions, oldShowSubscriptionsData);
      },
      validateItems: (newDb) async {
        expect(expectedNewGroupsData, await newDb.select(newDb.groups).get());
        expect(expectedNewCardsData, await newDb.select(newDb.cards).get());
        expect(expectedNewNfcTagsData, await newDb.select(newDb.nfcTags).get());
        expect(
          expectedNewShowSubscriptionsData,
          await newDb.select(newDb.showSubscriptions).get(),
        );
      },
    );
  });
}
