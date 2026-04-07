/// Expired content: items past their availableUntil are hidden from kids.
///
/// ARD content rotates (typically 6-12 month availability windows).
/// Expired items must be hidden from the kid grid and tile detail screen
/// but remain in the database for parent management.
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
    'expired ungrouped item is hidden from kid home screen',
    ($) async {
      await pumpApp($, prefs: {'onboarding_complete': true});
      await clearAppState($);

      final container = getContainer($);
      final items = container.read(tileItemRepositoryProvider);

      // Insert an expired ARD episode (availableUntil in the past).
      await items.insertArdEpisode(
        title: 'Expired Episode',
        providerUri: 'ard:item:expired-test-123',
        audioUrl: 'https://example.com/audio.mp3',
        durationMs: 60000,
        availableUntil: DateTime(2020),
      );
      await pumpFrames($);

      // The expired item should NOT appear in the kid grid.
      expect(find.text('Expired Episode'), findsNothing);
      expect(find.byType(TileItem), findsNothing);
    },
  );

  patrolTest(
    'expired item inside tile is hidden from tile detail',
    ($) async {
      await pumpApp($, prefs: {'onboarding_complete': true});
      await clearAppState($);

      final container = getContainer($);
      final tiles = container.read(tileRepositoryProvider);
      final items = container.read(tileItemRepositoryProvider);

      // Create a tile with one valid and one expired episode.
      final tileId = await tiles.insert(title: 'Mixed Tile');
      await items.insertArdEpisode(
        title: 'Valid Episode',
        providerUri: 'ard:item:valid-test-123',
        audioUrl: 'https://example.com/valid.mp3',
        durationMs: 60000,
        tileId: tileId,
      );
      await items.insertArdEpisode(
        title: 'Expired Episode',
        providerUri: 'ard:item:expired-test-456',
        audioUrl: 'https://example.com/expired.mp3',
        durationMs: 60000,
        tileId: tileId,
        availableUntil: DateTime(2020),
      );
      await pumpFrames($);

      // Both items exist in DB.
      final allItems = await items.getAll();
      final tileItems = allItems.where((i) => i.groupId == tileId).toList();
      expect(tileItems, hasLength(2), reason: 'Both items in DB');

      // Tile should appear on home screen (it has valid content).
      expect(find.byType(TileCard), findsOneWidget);

      // Navigate to tile detail.
      container.read(appRouterProvider).go(AppRoutes.tileDetail(tileId));
      await pumpFrames($);

      // Only the valid episode should be visible. Expired one hidden.
      expect(find.byType(TileItem), findsOneWidget);
      expect(find.text('Valid Episode'), findsOneWidget);
      expect(
        find.text('Expired Episode'),
        findsNothing,
        reason: 'Expired episode must not be visible to kids',
      );
    },
  );

  patrolTest(
    'expired items still exist in database for parent management',
    ($) async {
      await pumpApp($, prefs: {'onboarding_complete': true});
      await clearAppState($);

      final container = getContainer($);
      final items = container.read(tileItemRepositoryProvider);

      await items.insertArdEpisode(
        title: 'Expired DB Test',
        providerUri: 'ard:item:expired-db-test',
        audioUrl: 'https://example.com/expired.mp3',
        durationMs: 60000,
        availableUntil: DateTime(2020),
      );

      // Item exists in DB regardless of expiration.
      final all = await items.getAll();
      expect(all.any((i) => i.title == 'Expired DB Test'), isTrue);

      // But isItemExpired correctly identifies it.
      final expired = all.firstWhere((i) => i.title == 'Expired DB Test');
      expect(isItemExpired(expired), isTrue);
    },
  );
}
