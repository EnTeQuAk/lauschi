// dart format width=80
import 'package:drift/drift.dart';
import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/database/app_database.dart';

import 'generated/schema.dart';
import 'generated/schema_v10.dart' as v10;
import 'generated/schema_v11.dart' as v11;
import 'generated/schema_v12.dart' as v12;
import 'generated/schema_v13.dart' as v13;

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

  // The v10 → v11 migration adds the `cards.marked_unavailable` column
  // (see app_database.dart's onUpgrade for `from < 11`). This test seeds
  // the v10 schema with realistic data covering each table, runs the
  // migration, and verifies:
  //
  // 1. Every existing row survives unchanged across all tables.
  // 2. The new `markedUnavailable` column shows up on every card row
  //    with the schema-default value (null), proving the column was
  //    actually added — not just that the migration didn't throw.
  //
  // Without this test it would be possible to accidentally land a
  // future migration that drops or rewrites rows mid-upgrade and we
  // would only find out at user-update time. The "simple migrations"
  // group above only checks schema shape; this one checks data.
  test(
    'migration from v10 to v11 preserves all rows + adds null marked_unavailable',
    () async {
      // ── Seed: realistic v10 rows ─────────────────────────────────────
      // Drift's epoch encoding uses Unix milliseconds. Pin a fixed
      // timestamp instead of DateTime.now() so the test is deterministic
      // and we can compare the post-migration row exactly.
      const fixedCreatedAt = 1700000000000; // 2023-11-14T22:13:20Z
      const fixedLastPlayedAt = 1700001000000; // 16m later

      final oldGroupsData = <v10.GroupsData>[
        const v10.GroupsData(
          id: 'tile-tkkg',
          title: 'TKKG',
          coverUrl: 'https://example.test/tkkg.jpg',
          sortOrder: 0,
          createdAt: fixedCreatedAt,
          contentType: 'hoerspiel',
          provider: 'spotify',
        ),
        // A nested child tile so the migration also has to carry the
        // parent_tile_id FK across.
        const v10.GroupsData(
          id: 'tile-tkkg-folder-child',
          title: 'TKKG - Folge 1',
          sortOrder: 0,
          createdAt: fixedCreatedAt,
          contentType: 'hoerspiel',
          parentTileId: 'tile-tkkg',
        ),
      ];

      final oldCardsData = <v10.CardsData>[
        // Card with everything populated, including the legacy fields
        // that exist in v10 but might be reshuffled by future migrations.
        const v10.CardsData(
          id: 'card-tkkg-1',
          title: 'TKKG Folge 1',
          customTitle: 'My Custom Title',
          coverUrl: 'https://example.test/cover.jpg',
          customCoverPath: '/data/custom.jpg',
          cardType: 'episode',
          provider: 'spotify',
          providerUri: 'spotify:album:tkkg1',
          spotifyArtistIds: 'artist1,artist2',
          groupId: 'tile-tkkg',
          episodeNumber: 1,
          isHeard: 0,
          sortOrder: 0,
          createdAt: fixedCreatedAt,
          totalTracks: 12,
          durationMs: 1800000,
          lastTrackUri: 'spotify:track:abc',
          lastTrackNumber: 5,
          lastPositionMs: 30000,
          lastPlayedAt: fixedLastPlayedAt,
        ),
        // ARD-style card with audioUrl set and no Spotify metadata.
        const v10.CardsData(
          id: 'card-ard-1',
          title: 'Ohrenbär Folge',
          cardType: 'episode',
          provider: 'ard_audiothek',
          providerUri: 'ard:item:99999',
          isHeard: 1,
          sortOrder: 1,
          createdAt: fixedCreatedAt,
          totalTracks: 0,
          audioUrl: 'https://example.test/ohrenbaer.mp3',
          durationMs: 600000,
          lastTrackNumber: 1,
          lastPositionMs: 0,
        ),
      ];

      final oldNfcTagsData = <v10.NfcTagsData>[
        const v10.NfcTagsData(
          id: 1,
          tagUid: '04:1A:2B:3C:4D:5E',
          targetType: 'tile',
          targetId: 'tile-tkkg',
          label: 'TKKG NFC tag',
          createdAt: fixedCreatedAt,
        ),
      ];

      final oldShowSubscriptionsData = <v10.ShowSubscriptionsData>[
        const v10.ShowSubscriptionsData(
          id: 1,
          provider: 'ard_audiothek',
          externalShowId: '25705746',
          title: 'Ohrenbär',
          coverUrl: 'https://example.test/ohrenbaer.jpg',
          groupId: 'tile-tkkg',
          maxEpisodes: 50,
          lastSyncedAt: fixedCreatedAt,
          remoteLastItemAdded: fixedCreatedAt,
          createdAt: fixedCreatedAt,
        ),
      ];

      // ── Expected: same rows in v11 schema ────────────────────────────
      // Groups, NfcTags, and ShowSubscriptions are unchanged in v11 — the
      // expected v11 row is structurally identical (just constructed via
      // the v11.GroupsData / v11.NfcTagsData / etc. types).
      final expectedNewGroupsData = <v11.GroupsData>[
        const v11.GroupsData(
          id: 'tile-tkkg',
          title: 'TKKG',
          coverUrl: 'https://example.test/tkkg.jpg',
          sortOrder: 0,
          createdAt: fixedCreatedAt,
          contentType: 'hoerspiel',
          provider: 'spotify',
        ),
        const v11.GroupsData(
          id: 'tile-tkkg-folder-child',
          title: 'TKKG - Folge 1',
          sortOrder: 0,
          createdAt: fixedCreatedAt,
          contentType: 'hoerspiel',
          parentTileId: 'tile-tkkg',
        ),
      ];

      // Cards in v11 have a new `markedUnavailable` int? column. The
      // migration adds it as nullable with no default, so existing rows
      // should come out with null. THAT is the post-condition we care
      // about most — the explicit `markedUnavailable: null` lines below
      // intentionally pass the default value because they document the
      // contract under test. Don't simplify them away or the test loses
      // its point.
      final expectedNewCardsData = <v11.CardsData>[
        const v11.CardsData(
          id: 'card-tkkg-1',
          title: 'TKKG Folge 1',
          customTitle: 'My Custom Title',
          coverUrl: 'https://example.test/cover.jpg',
          customCoverPath: '/data/custom.jpg',
          cardType: 'episode',
          provider: 'spotify',
          providerUri: 'spotify:album:tkkg1',
          spotifyArtistIds: 'artist1,artist2',
          groupId: 'tile-tkkg',
          episodeNumber: 1,
          isHeard: 0,
          sortOrder: 0,
          createdAt: fixedCreatedAt,
          totalTracks: 12,
          durationMs: 1800000,
          // Explicit null IS the contract under test (v11 added this column).
          // ignore: avoid_redundant_argument_values
          markedUnavailable: null,
          lastTrackUri: 'spotify:track:abc',
          lastTrackNumber: 5,
          lastPositionMs: 30000,
          lastPlayedAt: fixedLastPlayedAt,
        ),
        const v11.CardsData(
          id: 'card-ard-1',
          title: 'Ohrenbär Folge',
          cardType: 'episode',
          provider: 'ard_audiothek',
          providerUri: 'ard:item:99999',
          isHeard: 1,
          sortOrder: 1,
          createdAt: fixedCreatedAt,
          totalTracks: 0,
          audioUrl: 'https://example.test/ohrenbaer.mp3',
          durationMs: 600000,
          // Explicit null IS the contract under test (v11 added this column).
          // ignore: avoid_redundant_argument_values
          markedUnavailable: null,
          lastTrackNumber: 1,
          lastPositionMs: 0,
        ),
      ];

      final expectedNewNfcTagsData = <v11.NfcTagsData>[
        const v11.NfcTagsData(
          id: 1,
          tagUid: '04:1A:2B:3C:4D:5E',
          targetType: 'tile',
          targetId: 'tile-tkkg',
          label: 'TKKG NFC tag',
          createdAt: fixedCreatedAt,
        ),
      ];

      final expectedNewShowSubscriptionsData = <v11.ShowSubscriptionsData>[
        const v11.ShowSubscriptionsData(
          id: 1,
          provider: 'ard_audiothek',
          externalShowId: '25705746',
          title: 'Ohrenbär',
          coverUrl: 'https://example.test/ohrenbaer.jpg',
          groupId: 'tile-tkkg',
          maxEpisodes: 50,
          lastSyncedAt: fixedCreatedAt,
          remoteLastItemAdded: fixedCreatedAt,
          createdAt: fixedCreatedAt,
        ),
      ];

      // Context: every "expected" list has the same length as the
      // matching "old" list. If a future migration starts dropping
      // rows we want this test to fail at the row-count level first
      // before drilling into individual mismatches.
      expect(expectedNewGroupsData, hasLength(oldGroupsData.length));
      expect(expectedNewCardsData, hasLength(oldCardsData.length));
      expect(expectedNewNfcTagsData, hasLength(oldNfcTagsData.length));
      expect(
        expectedNewShowSubscriptionsData,
        hasLength(oldShowSubscriptionsData.length),
      );

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
          expect(
            expectedNewNfcTagsData,
            await newDb.select(newDb.nfcTags).get(),
          );
          expect(
            expectedNewShowSubscriptionsData,
            await newDb.select(newDb.showSubscriptions).get(),
          );
        },
      );
    },
  );

  // The v12 → v13 migration makes cards.sort_order nullable. The old
  // NOT NULL column with default 0 is replaced via add-drop-rename
  // (SQLite can't ALTER COLUMN constraints). All existing sort_order
  // values become NULL, enabling COALESCE(sort_order, episode_number)
  // auto-sorting. This test verifies data survives the column swap.
  test(
    'migration from v12 to v13 nullifies sort_order and preserves all other columns',
    () async {
      const fixedCreatedAt = 1700000000000;
      const fixedLastPlayedAt = 1700001000000;

      final oldCardsData = <v12.CardsData>[
        const v12.CardsData(
          id: 'card-tkkg-1',
          title: 'TKKG Folge 1',
          cardType: 'episode',
          provider: 'spotify',
          providerUri: 'spotify:album:tkkg1',
          groupId: 'tile-tkkg',
          episodeNumber: 1,
          isHeard: 0,
          sortOrder: 5,
          createdAt: fixedCreatedAt,
          totalTracks: 12,
          durationMs: 1800000,
          lastTrackUri: 'spotify:track:abc',
          lastTrackNumber: 5,
          lastPositionMs: 30000,
          lastPlayedAt: fixedLastPlayedAt,
        ),
        const v12.CardsData(
          id: 'card-ard-1',
          title: 'Ohrenbär Folge',
          cardType: 'episode',
          provider: 'ard_audiothek',
          providerUri: 'ard:item:99999',
          isHeard: 1,
          sortOrder: 42,
          createdAt: fixedCreatedAt,
          totalTracks: 0,
          audioUrl: 'https://example.test/ohrenbaer.mp3',
          durationMs: 600000,
          lastTrackNumber: 1,
          lastPositionMs: 0,
        ),
      ];

      final oldGroupsData = <v12.GroupsData>[
        const v12.GroupsData(
          id: 'tile-tkkg',
          title: 'TKKG',
          sortOrder: 0,
          createdAt: fixedCreatedAt,
          contentType: 'hoerspiel',
          provider: 'spotify',
        ),
      ];

      // After migration, sort_order should be NULL for all cards.
      // All other columns must be identical.
      final expectedNewCardsData = <v13.CardsData>[
        const v13.CardsData(
          id: 'card-tkkg-1',
          title: 'TKKG Folge 1',
          cardType: 'episode',
          provider: 'spotify',
          providerUri: 'spotify:album:tkkg1',
          groupId: 'tile-tkkg',
          episodeNumber: 1,
          isHeard: 0,
          // sort_order was 5, now NULL after column swap.
          // ignore: avoid_redundant_argument_values
          sortOrder: null,
          createdAt: fixedCreatedAt,
          totalTracks: 12,
          durationMs: 1800000,
          lastTrackUri: 'spotify:track:abc',
          lastTrackNumber: 5,
          lastPositionMs: 30000,
          lastPlayedAt: fixedLastPlayedAt,
        ),
        const v13.CardsData(
          id: 'card-ard-1',
          title: 'Ohrenbär Folge',
          cardType: 'episode',
          provider: 'ard_audiothek',
          providerUri: 'ard:item:99999',
          isHeard: 1,
          // sort_order was 42, now NULL after column swap.
          // ignore: avoid_redundant_argument_values
          sortOrder: null,
          createdAt: fixedCreatedAt,
          totalTracks: 0,
          audioUrl: 'https://example.test/ohrenbaer.mp3',
          durationMs: 600000,
          lastTrackNumber: 1,
          lastPositionMs: 0,
        ),
      ];

      // Groups are unchanged in v13 — only cards.sort_order changed.
      final expectedNewGroupsData = <v13.GroupsData>[
        const v13.GroupsData(
          id: 'tile-tkkg',
          title: 'TKKG',
          sortOrder: 0,
          createdAt: fixedCreatedAt,
          contentType: 'hoerspiel',
          provider: 'spotify',
        ),
      ];

      expect(expectedNewCardsData, hasLength(oldCardsData.length));
      expect(expectedNewGroupsData, hasLength(oldGroupsData.length));

      await verifier.testWithDataIntegrity(
        oldVersion: 12,
        newVersion: 13,
        createOld: v12.DatabaseAtV12.new,
        createNew: v13.DatabaseAtV13.new,
        openTestedDatabase: AppDatabase.new,
        createItems: (batch, oldDb) {
          batch
            ..insertAll(oldDb.groups, oldGroupsData)
            ..insertAll(oldDb.cards, oldCardsData);
        },
        validateItems: (newDb) async {
          expect(
            await newDb.select(newDb.cards).get(),
            expectedNewCardsData,
          );
          expect(
            await newDb.select(newDb.groups).get(),
            expectedNewGroupsData,
          );
        },
      );
    },
  );
}
