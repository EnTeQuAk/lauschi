/// Tile nesting smoke tests.
///
/// Verifies that the parentTileId-based nesting works end-to-end:
/// creating nested tiles, kid navigation, unnesting.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/auth/pin_service.dart';
import 'package:lauschi/core/database/tile_repository.dart';
import 'package:lauschi/core/router/app_router.dart';
import 'package:lauschi/features/player/player_provider.dart';
import 'package:lauschi/features/tiles/widgets/tile_card.dart';
import 'package:patrol/patrol.dart';

import 'ard_helpers.dart';
import 'helpers.dart';

void main() {
  patrolTest(
    'nested tiles appear inside parent, not on home screen',
    ($) async {
      await pumpApp(
        $,
        prefs: {'onboarding_complete': true},
        scope:
            (child) => ProviderScope(
              overrides: [
                mediaSessionHandlerProvider.overrideWithValue(mediaHandler),
                parentAuthProvider.overrideWith(_AlwaysAuth.new),
              ],
              child: child,
            ),
      );

      final container = getContainer($);
      final tiles = container.read(tileRepositoryProvider);

      // Create a parent tile and a child tile.
      final parentId = await tiles.insert(title: 'Senta');
      final childId = await tiles.insert(title: 'Hoch die Hände');
      await tiles.nestInto(childId: childId, parentId: parentId);
      await pumpFrames($);

      // Home screen: only the parent should be visible.
      final rootTiles = await tiles.getAll();
      expect(rootTiles, hasLength(1));
      expect(rootTiles.first.title, 'Senta');

      // The child should not be in rootTiles.
      final allTiles = await tiles.getAllFlat();
      expect(allTiles, hasLength(2));

      // Child should be accessible via getChildren.
      final children = await tiles.getChildren(parentId);
      expect(children, hasLength(1));
      expect(children.first.title, 'Hoch die Hände');

      // Home screen should show exactly one TileCard.
      expect(find.byType(TileCard), findsOneWidget);
    },
  );

  patrolTest(
    'groupTiles creates parent and nests two tiles',
    ($) async {
      await pumpApp(
        $,
        prefs: {'onboarding_complete': true},
        scope:
            (child) => ProviderScope(
              overrides: [
                mediaSessionHandlerProvider.overrideWithValue(mediaHandler),
                parentAuthProvider.overrideWith(_AlwaysAuth.new),
              ],
              child: child,
            ),
      );

      final container = getContainer($);
      final tiles = container.read(tileRepositoryProvider);

      // Create two standalone tiles.
      final tile1 = await tiles.insert(title: 'Album A');
      final tile2 = await tiles.insert(title: 'Album B');
      await pumpFrames($);

      // Precondition: both are root tiles.
      final beforeRoot = await tiles.getAll();
      expect(beforeRoot, hasLength(2));
      expect(
        beforeRoot.map((t) => t.title),
        containsAll(['Album A', 'Album B']),
      );
      expect(await tiles.getAllFlat(), hasLength(2));

      // Group them.
      final parentId = await tiles.groupTiles(
        tileId1: tile1,
        tileId2: tile2,
        groupTitle: 'Senta',
      );
      await pumpFrames($);

      // Root should now have 1 tile (the parent), not 3.
      final rootTiles = await tiles.getAll();
      expect(rootTiles, hasLength(1));
      expect(rootTiles.first.id, parentId);
      expect(rootTiles.first.title, 'Senta');

      // Total tiles: parent + 2 children = 3.
      expect(await tiles.getAllFlat(), hasLength(3));

      // Parent should have 2 children with correct titles.
      final children = await tiles.getChildren(parentId);
      expect(children, hasLength(2));
      expect(children.map((t) => t.title), containsAll(['Album A', 'Album B']));
    },
  );

  patrolTest(
    'unnest moves tile back to root',
    ($) async {
      await pumpApp(
        $,
        prefs: {'onboarding_complete': true},
        scope:
            (child) => ProviderScope(
              overrides: [
                mediaSessionHandlerProvider.overrideWithValue(mediaHandler),
                parentAuthProvider.overrideWith(_AlwaysAuth.new),
              ],
              child: child,
            ),
      );

      final container = getContainer($);
      final tiles = container.read(tileRepositoryProvider);

      // Create nested structure.
      final parentId = await tiles.insert(title: 'Parent');
      final childId = await tiles.insert(title: 'Child');
      await tiles.nestInto(childId: childId, parentId: parentId);
      await pumpFrames($);

      expect(await tiles.getAll(), hasLength(1));

      // Unnest.
      await tiles.unnest(childId);
      await pumpFrames($);

      // Both should be root tiles now.
      final rootTiles = await tiles.getAll();
      expect(rootTiles, hasLength(2));
    },
  );

  patrolTest(
    'cycle prevention rejects self-nesting',
    ($) async {
      await pumpApp(
        $,
        prefs: {'onboarding_complete': true},
        scope:
            (child) => ProviderScope(
              overrides: [
                mediaSessionHandlerProvider.overrideWithValue(mediaHandler),
                parentAuthProvider.overrideWith(_AlwaysAuth.new),
              ],
              child: child,
            ),
      );

      final container = getContainer($);
      final tiles = container.read(tileRepositoryProvider);
      final tileId = await tiles.insert(title: 'Self');

      // Self-nesting should throw.
      expect(
        () => tiles.nestInto(childId: tileId, parentId: tileId),
        throwsArgumentError,
      );
    },
  );

  patrolTest(
    'cycle prevention rejects ancestor nesting into descendant',
    ($) async {
      await pumpApp(
        $,
        prefs: {'onboarding_complete': true},
        scope:
            (child) => ProviderScope(
              overrides: [
                mediaSessionHandlerProvider.overrideWithValue(mediaHandler),
                parentAuthProvider.overrideWith(_AlwaysAuth.new),
              ],
              child: child,
            ),
      );

      final container = getContainer($);
      final tiles = container.read(tileRepositoryProvider);

      // Create: grandparent → parent → child.
      final grandparentId = await tiles.insert(title: 'Grandparent');
      final parentId = await tiles.insert(title: 'Parent');
      final childId = await tiles.insert(title: 'Child');
      await tiles.nestInto(childId: parentId, parentId: grandparentId);
      await tiles.nestInto(childId: childId, parentId: parentId);

      // Nesting grandparent into child would create a cycle.
      expect(
        () => tiles.nestInto(childId: grandparentId, parentId: childId),
        throwsArgumentError,
      );
    },
  );

  patrolTest(
    'delete parent cascades to children',
    ($) async {
      await pumpApp(
        $,
        prefs: {'onboarding_complete': true},
        scope:
            (child) => ProviderScope(
              overrides: [
                mediaSessionHandlerProvider.overrideWithValue(mediaHandler),
                parentAuthProvider.overrideWith(_AlwaysAuth.new),
              ],
              child: child,
            ),
      );

      final container = getContainer($);
      final tiles = container.read(tileRepositoryProvider);

      final parentId = await tiles.insert(title: 'Parent');
      await tiles.insert(title: 'Child A');
      await tiles.insert(title: 'Child B');
      final allBefore = await tiles.getAllFlat();
      // Nest children.
      await tiles.nestInto(childId: allBefore[1].id, parentId: parentId);
      await tiles.nestInto(childId: allBefore[2].id, parentId: parentId);

      expect(await tiles.getAllFlat(), hasLength(3));

      // Delete parent.
      await tiles.delete(parentId);
      await pumpFrames($);

      // Everything should be gone.
      expect(await tiles.getAllFlat(), hasLength(0));
    },
  );

  patrolTest(
    'kid can navigate into nested tile',
    ($) async {
      await pumpApp(
        $,
        prefs: {'onboarding_complete': true},
        scope:
            (child) => ProviderScope(
              overrides: [
                mediaSessionHandlerProvider.overrideWithValue(mediaHandler),
                parentAuthProvider.overrideWith(_AlwaysAuth.new),
              ],
              child: child,
            ),
      );

      final container = getContainer($);
      final tiles = container.read(tileRepositoryProvider);
      final episode = await getStableTestEpisode(container);

      // Create parent tile with a child tile that has an episode.
      final parentId = await tiles.insert(title: 'Senta');
      final result = await insertTestTileWithEpisode(
        $,
        episode,
        title: 'Hoch die Hände',
      );
      await tiles.nestInto(childId: result.tileId, parentId: parentId);
      await pumpFrames($, count: 5);

      // Home screen: tap parent tile.
      final parentTile = find.byType(TileCard);
      expect(parentTile, findsOneWidget);

      // Navigate to parent's detail screen.
      container
          .read(appRouterProvider)
          .go(
            AppRoutes.tileDetail(parentId),
          );
      await pumpFrames($, count: 10);

      // Should see the child tile inside.
      expect(find.byType(TileCard), findsOneWidget);
    },
  );
  patrolTest(
    'deep nesting (5 levels) and cascading delete',
    ($) async {
      await pumpApp(
        $,
        prefs: {'onboarding_complete': true},
        scope:
            (child) => ProviderScope(
              overrides: [
                mediaSessionHandlerProvider.overrideWithValue(mediaHandler),
                parentAuthProvider.overrideWith(_AlwaysAuth.new),
              ],
              child: child,
            ),
      );

      final container = getContainer($);
      final tiles = container.read(tileRepositoryProvider);

      // Create 5 levels: L0 → L1 → L2 → L3 → L4.
      final ids = <String>[];
      for (var i = 0; i < 5; i++) {
        ids.add(await tiles.insert(title: 'Level $i'));
      }
      for (var i = 1; i < 5; i++) {
        await tiles.nestInto(childId: ids[i], parentId: ids[i - 1]);
      }
      await pumpFrames($);

      // Root has exactly 1 tile (L0).
      expect(await tiles.getAll(), hasLength(1));

      // Each level has exactly 1 child.
      for (var i = 0; i < 4; i++) {
        final children = await tiles.getChildren(ids[i]);
        expect(children, hasLength(1), reason: 'Level $i should have 1 child');
        expect(children.first.id, ids[i + 1]);
      }

      // L4 (deepest) has no children.
      expect(await tiles.getChildren(ids[4]), isEmpty);

      // All 5 tiles exist.
      expect(await tiles.getAllFlat(), hasLength(5));

      // Delete root: entire subtree should be gone.
      await tiles.delete(ids[0]);
      await pumpFrames($);
      expect(await tiles.getAllFlat(), isEmpty);
    },
  );
}

class _AlwaysAuth extends ParentAuth {
  @override
  bool build() => true;
}
