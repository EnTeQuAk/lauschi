/// Tile nesting smoke tests.
///
/// Verifies that the parentTileId-based nesting works end-to-end:
/// creating nested tiles, kid navigation, unnesting.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/auth/pin_service.dart';
import 'package:lauschi/core/database/tile_repository.dart';
import 'package:lauschi/core/router/app_router.dart';
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
        overrides: [parentAuthProvider.overrideWith(_AlwaysAuth.new)],
      );
      await clearAppState($);

      final container = getContainer($);
      final tiles = container.read(tileRepositoryProvider);

      // Precondition: clearAppState left the DB empty. The other tests
      // in this file rely on this implicitly via count assertions; we
      // assert it explicitly here as documentation for new readers.
      expect(
        await tiles.getAllFlat(),
        isEmpty,
        reason: 'clearAppState should leave 0 tiles before test setup',
      );

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
    'createFolderFromDrag creates folder and nests two tiles',
    ($) async {
      await pumpApp(
        $,
        prefs: {'onboarding_complete': true},
        overrides: [parentAuthProvider.overrideWith(_AlwaysAuth.new)],
      );
      await clearAppState($);

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

      // Create folder by dragging tile1 onto tile2.
      final folderId = await tiles.createFolderFromDrag(
        draggedId: tile1,
        targetId: tile2,
      );
      await pumpFrames($);

      // Root should now have 1 tile (the folder), not 3.
      final rootTiles = await tiles.getAll();
      expect(rootTiles, hasLength(1));
      expect(rootTiles.first.id, folderId);
      expect(rootTiles.first.title, 'Neuer Ordner');

      // Total tiles: folder + 2 children = 3.
      expect(await tiles.getAllFlat(), hasLength(3));

      // Folder should have 2 children with correct titles and parent link.
      final children = await tiles.getChildren(folderId);
      expect(children, hasLength(2));
      expect(children.map((t) => t.title), containsAll(['Album A', 'Album B']));
      for (final child in children) {
        expect(
          child.parentTileId,
          folderId,
          reason: 'Child should reference the folder',
        );
      }
      // Children should not appear as root tiles.
      final rootIds = rootTiles.map((t) => t.id).toSet();
      expect(rootIds.contains(tile1), isFalse);
      expect(rootIds.contains(tile2), isFalse);
    },
  );

  patrolTest(
    'unnest moves tile back to root',
    ($) async {
      await pumpApp(
        $,
        prefs: {'onboarding_complete': true},
        overrides: [parentAuthProvider.overrideWith(_AlwaysAuth.new)],
      );
      await clearAppState($);

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

      // Child should be at root. Parent (empty folder with no content)
      // is auto-dissolved by _dissolveIfEmpty.
      final rootTiles = await tiles.getAll();
      expect(rootTiles, hasLength(1));
      expect(rootTiles.first.title, 'Child');
    },
  );

  patrolTest(
    'folder lifecycle: create → unnest one (stays) → unnest last (dissolves)',
    ($) async {
      await pumpApp(
        $,
        prefs: {'onboarding_complete': true},
        overrides: [parentAuthProvider.overrideWith(_AlwaysAuth.new)],
      );
      await clearAppState($);

      final container = getContainer($);
      final tiles = container.read(tileRepositoryProvider);

      // Create two leaf tiles.
      final tileA = await tiles.insert(title: 'Ohrenbär');
      final tileB = await tiles.insert(title: 'Sandmännchen');
      await pumpFrames($);

      expect(await tiles.getAll(), hasLength(2));
      expect(await tiles.getAllFlat(), hasLength(2));

      // Drag A onto B → creates a folder with both inside.
      final folderId = await tiles.createFolderFromDrag(
        draggedId: tileA,
        targetId: tileB,
      );
      await pumpFrames($);

      // Root should have 1 tile (the folder).
      final rootAfterCreate = await tiles.getAll();
      expect(rootAfterCreate, hasLength(1));
      expect(rootAfterCreate.first.id, folderId);
      expect(rootAfterCreate.first.title, 'Neuer Ordner');

      // Folder should have 2 children.
      final children = await tiles.getChildren(folderId);
      expect(children, hasLength(2));
      final childIds = children.map((t) => t.id).toSet();
      expect(childIds, containsAll([tileA, tileB]));

      // Total tiles: folder + 2 children = 3.
      expect(await tiles.getAllFlat(), hasLength(3));

      // Unnest tileA. Folder should stay (still has tileB).
      await tiles.unnest(tileA);
      await pumpFrames($);

      final rootAfterFirst = await tiles.getAll();
      expect(
        rootAfterFirst,
        hasLength(2),
        reason: 'Root should have folder + unnested tileA',
      );
      expect(
        rootAfterFirst.map((t) => t.id).toSet(),
        containsAll([folderId, tileA]),
      );

      // Folder still has 1 child (tileB).
      final remainingChildren = await tiles.getChildren(folderId);
      expect(remainingChildren, hasLength(1));
      expect(remainingChildren.first.id, tileB);

      // Unnest tileB. Folder should dissolve (0 children, no content).
      await tiles.unnest(tileB);
      await pumpFrames($);

      final rootAfterSecond = await tiles.getAll();
      expect(
        rootAfterSecond,
        hasLength(2),
        reason: 'Root should have tileA + tileB (folder dissolved)',
      );
      final rootIds = rootAfterSecond.map((t) => t.id).toSet();
      expect(rootIds, containsAll([tileA, tileB]));
      expect(
        rootIds.contains(folderId),
        isFalse,
        reason: 'Empty folder should be dissolved',
      );

      // Total tiles back to 2 (no orphaned folder).
      expect(await tiles.getAllFlat(), hasLength(2));
    },
  );

  patrolTest(
    'cycle prevention rejects self-nesting',
    ($) async {
      await pumpApp(
        $,
        prefs: {'onboarding_complete': true},
        overrides: [parentAuthProvider.overrideWith(_AlwaysAuth.new)],
      );
      await clearAppState($);

      final container = getContainer($);
      final tiles = container.read(tileRepositoryProvider);
      final tileId = await tiles.insert(title: 'Self');

      // Setup precondition: tile is fresh, parentTileId is null.
      final before = await tiles.getById(tileId);
      expect(before, isNotNull);
      expect(
        before!.parentTileId,
        isNull,
        reason: 'fresh tile has no parent',
      );

      // Self-nesting should throw.
      expect(
        () => tiles.nestInto(childId: tileId, parentId: tileId),
        throwsArgumentError,
      );

      // Postcondition (round-1 review H7): the failed nestInto must
      // not have partially corrupted the tile's parentTileId. Without
      // this check, a future bug that wrote parentTileId BEFORE
      // throwing would silently leave the DB in a self-referencing
      // state.
      final after = await tiles.getById(tileId);
      expect(after, isNotNull);
      expect(
        after!.parentTileId,
        isNull,
        reason: 'failed self-nesting must not have set parentTileId',
      );
    },
  );

  patrolTest(
    'cycle prevention rejects ancestor nesting into descendant',
    ($) async {
      await pumpApp(
        $,
        prefs: {'onboarding_complete': true},
        overrides: [parentAuthProvider.overrideWith(_AlwaysAuth.new)],
      );
      await clearAppState($);

      final container = getContainer($);
      final tiles = container.read(tileRepositoryProvider);

      // Create: grandparent → parent → child.
      final grandparentId = await tiles.insert(title: 'Grandparent');
      final parentId = await tiles.insert(title: 'Parent');
      final childId = await tiles.insert(title: 'Child');
      await tiles.nestInto(childId: parentId, parentId: grandparentId);
      await tiles.nestInto(childId: childId, parentId: parentId);

      // Setup precondition: the chain is the shape we expect before
      // we try to break it.
      final beforeGrandparent = await tiles.getById(grandparentId);
      final beforeParent = await tiles.getById(parentId);
      final beforeChild = await tiles.getById(childId);
      expect(beforeGrandparent?.parentTileId, isNull);
      expect(beforeParent?.parentTileId, grandparentId);
      expect(beforeChild?.parentTileId, parentId);

      // Nesting grandparent into child would create a cycle.
      expect(
        () => tiles.nestInto(childId: grandparentId, parentId: childId),
        throwsArgumentError,
      );

      // Postcondition: the existing chain is unchanged. A bug that
      // wrote parentTileId before validating would corrupt the
      // grandparent's parent into the child id.
      final afterGrandparent = await tiles.getById(grandparentId);
      expect(
        afterGrandparent?.parentTileId,
        isNull,
        reason: 'failed cycle nestInto must not have set grandparent parent',
      );
    },
  );

  patrolTest(
    'delete parent cascades to children',
    ($) async {
      await pumpApp(
        $,
        prefs: {'onboarding_complete': true},
        overrides: [parentAuthProvider.overrideWith(_AlwaysAuth.new)],
      );
      await clearAppState($);

      final container = getContainer($);
      final tiles = container.read(tileRepositoryProvider);

      // Capture IDs from insert() returns instead of relying on
      // getAllFlat() index ordering (round-1 review H8). The previous
      // version used `allBefore[1].id` and `allBefore[2].id` which
      // assumes a specific sort order — if getAllFlat ever sorts by
      // title or createdAt-desc, the indices would point at the
      // wrong tiles.
      final parentId = await tiles.insert(title: 'Parent');
      final childAId = await tiles.insert(title: 'Child A');
      final childBId = await tiles.insert(title: 'Child B');
      // Nest children.
      await tiles.nestInto(childId: childAId, parentId: parentId);
      await tiles.nestInto(childId: childBId, parentId: parentId);

      // Setup precondition: the children are actually nested before
      // we delete the parent. If nestInto silently failed, the
      // delete cascade test would pass for the wrong reason ("only
      // 1 tile gone after delete because the children were
      // ungrouped, not because they cascaded").
      final beforeChildA = await tiles.getById(childAId);
      final beforeChildB = await tiles.getById(childBId);
      expect(
        beforeChildA?.parentTileId,
        parentId,
        reason: 'Child A must be nested under Parent before delete',
      );
      expect(
        beforeChildB?.parentTileId,
        parentId,
        reason: 'Child B must be nested under Parent before delete',
      );
      expect(await tiles.getAllFlat(), hasLength(3));

      // Delete parent.
      await tiles.delete(parentId);
      await pumpFrames($);

      // Everything should be gone — both children were nested under
      // the parent so they cascade.
      expect(await tiles.getAllFlat(), hasLength(0));
      expect(
        await tiles.getById(childAId),
        isNull,
        reason: 'Child A must be deleted by cascade',
      );
      expect(
        await tiles.getById(childBId),
        isNull,
        reason: 'Child B must be deleted by cascade',
      );
    },
  );

  patrolTest(
    'kid can navigate into nested tile',
    ($) async {
      await pumpApp(
        $,
        prefs: {'onboarding_complete': true},
        overrides: [parentAuthProvider.overrideWith(_AlwaysAuth.new)],
      );
      await clearAppState($);

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
      await pumpFrames($);

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
        overrides: [parentAuthProvider.overrideWith(_AlwaysAuth.new)],
      );
      await clearAppState($);

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
