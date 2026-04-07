/// Items confirmed unavailable (`markedUnavailable` set) are hidden
/// from kids but remain in the database for parent management.
///
/// **CRITICAL DISTINCTION** (caught during round-1 test infra review):
/// The previous version of this file used `availableUntil: DateTime(2020)`
/// to create "expired" items. That field is the ARD broadcast-window
/// hint and is INFORMATIONAL ONLY — production code does NOT filter
/// on it. Audio URLs remain on CDN well past `endDate`. The actual
/// "hide from kids" filter (`isItemExpired` in tile_item_repository.dart)
/// only checks `markedUnavailable`, which the StreamPlayer sets when
/// playback fails with a non-recoverable error.
///
/// So the previous tests were testing the wrong thing: they created
/// items with stale `availableUntil` and asserted they were hidden,
/// but production wouldn't have hidden them. The tests were likely
/// either silently broken on device or the item insert wasn't actually
/// happening fast enough for the kid grid to render it before the
/// `findsNothing` assertion fired (a stream-timing false-positive).
///
/// Fixed: tests now use `markedUnavailable: DateTime(2020)` to mark
/// items as confirmed-unavailable, which is the actual production
/// trigger.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/database/tile_item_repository.dart';
import 'package:lauschi/core/database/tile_repository.dart';
import 'package:lauschi/core/router/app_router.dart';
import 'package:lauschi/features/tiles/widgets/audio_tile.dart';
import 'package:lauschi/features/tiles/widgets/tile_card.dart';
import 'package:patrol/patrol.dart';

import 'ard_helpers.dart';
import 'helpers.dart';

void main() {
  patrolTest(
    'unavailable ungrouped item is hidden from kid home screen',
    ($) async {
      await pumpApp($, prefs: {'onboarding_complete': true});
      await clearAppState($);

      final container = getContainer($);
      final items = container.read(tileItemRepositoryProvider);

      // Insert a confirmed-unavailable ARD episode. The DB write
      // sets markedUnavailable directly because the production
      // path that would set this (StreamPlayer playback failure)
      // can't be triggered without a real failing stream.
      final id = await items.insertArdEpisode(
        title: 'Unavailable Episode',
        providerUri: 'ard:item:unavailable-test-123',
        audioUrl: 'https://example.com/audio.mp3',
        durationMs: 60000,
      );
      await items.markUnavailable(id);

      // Context-assert: the item is actually in the DB AND its
      // markedUnavailable flag is set. Without these, a silent
      // insert failure or markUnavailable bug would let the
      // findsNothing assertion below pass for the wrong reason.
      final inDb = await items.getById(id);
      expect(inDb, isNotNull, reason: 'item must exist in DB');
      expect(
        inDb!.markedUnavailable,
        isNotNull,
        reason: 'markedUnavailable must be set so the kid grid hides it',
      );
      expect(
        isItemExpired(inDb),
        isTrue,
        reason: 'sanity: production isItemExpired agrees the item is hidden',
      );

      await pumpFrames($);

      // The unavailable item must NOT appear in the kid grid.
      expect(find.text('Unavailable Episode'), findsNothing);
      expect(find.byType(TileItem), findsNothing);
    },
  );

  patrolTest(
    'unavailable item inside tile is hidden from tile detail',
    ($) async {
      await pumpApp($, prefs: {'onboarding_complete': true});
      await clearAppState($);

      final container = getContainer($);
      final tiles = container.read(tileRepositoryProvider);
      final items = container.read(tileItemRepositoryProvider);

      // Create a tile with one valid and one unavailable episode.
      final tileId = await tiles.insert(title: 'Mixed Tile');
      await items.insertArdEpisode(
        title: 'Valid Episode',
        providerUri: 'ard:item:valid-test-123',
        audioUrl: 'https://example.com/valid.mp3',
        durationMs: 60000,
        tileId: tileId,
      );
      final unavailableId = await items.insertArdEpisode(
        title: 'Unavailable Episode',
        providerUri: 'ard:item:unavailable-test-456',
        audioUrl: 'https://example.com/expired.mp3',
        durationMs: 60000,
        tileId: tileId,
      );
      await items.markUnavailable(unavailableId);

      // Both items exist in DB.
      final allItems = await items.getAll();
      final tileItems = allItems.where((i) => i.groupId == tileId).toList();
      expect(tileItems, hasLength(2), reason: 'Both items in DB');

      // Context-assert: exactly one of the two has markedUnavailable.
      // Without this, a markUnavailable bug that no-ops would mean
      // the tile-detail filter would show 2 episodes instead of 1
      // and the test would fail with a misleading message.
      final markedCount =
          tileItems.where((i) => i.markedUnavailable != null).length;
      expect(
        markedCount,
        1,
        reason: 'exactly one item should be marked unavailable',
      );

      // Tile should appear on home screen (it has valid content).
      expect(find.byType(TileCard), findsOneWidget);

      // Navigate to tile detail.
      container.read(appRouterProvider).go(AppRoutes.tileDetail(tileId));
      await pumpFrames($);

      // Only the valid episode should be visible. Unavailable one hidden.
      expect(find.byType(TileItem), findsOneWidget);
      expect(find.text('Valid Episode'), findsOneWidget);
      expect(
        find.text('Unavailable Episode'),
        findsNothing,
        reason: 'Unavailable episode must not be visible to kids',
      );
    },
  );

  patrolTest(
    'unavailable items remain in database for parent management',
    ($) async {
      await pumpApp($, prefs: {'onboarding_complete': true});
      await clearAppState($);

      final container = getContainer($);
      final items = container.read(tileItemRepositoryProvider);

      final id = await items.insertArdEpisode(
        title: 'Unavailable DB Test',
        providerUri: 'ard:item:unavailable-db-test',
        audioUrl: 'https://example.com/expired.mp3',
        durationMs: 60000,
      );
      await items.markUnavailable(id);

      // Item exists in DB despite being marked unavailable.
      final all = await items.getAll();
      expect(all.any((i) => i.title == 'Unavailable DB Test'), isTrue);

      // And isItemExpired correctly identifies it.
      final unavailable = all.firstWhere(
        (i) => i.title == 'Unavailable DB Test',
      );
      expect(unavailable.markedUnavailable, isNotNull);
      expect(isItemExpired(unavailable), isTrue);
    },
  );
}
