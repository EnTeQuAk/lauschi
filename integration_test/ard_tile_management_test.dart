/// Tile management: create, rename, delete tiles via parent flow.
///
/// These tests don't involve audio — they test the parent dashboard UI
/// and database persistence for tile CRUD operations.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/auth/pin_service.dart';
import 'package:lauschi/core/database/tile_repository.dart';
import 'package:lauschi/features/player/player_provider.dart';
import 'package:lauschi/features/tiles/widgets/tile_card.dart';
import 'package:patrol/patrol.dart';

import 'ard_helpers.dart';
import 'helpers.dart';

void main() {
  patrolTest(
    'tiles created via DB appear in kid grid',
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
      final episode = await getStableTestEpisode(container);

      // Insert a tile with an episode.
      await insertTestTileWithEpisode($, episode, title: 'Testkachel');

      // ── Verify tile appears in kid grid as a TileCard widget ─────────
      expect($('Meine Hörspiele'), findsOneWidget);
      expect(
        find.byType(TileCard),
        findsOneWidget,
        reason: 'Tile should render as TileCard in kid grid',
      );

      // Also verify DB state.
      final tiles = await container.read(tileRepositoryProvider).getAll();
      expect(tiles, hasLength(1));
      expect(tiles.first.title, 'Testkachel');
    },
  );

  patrolTest(
    'tiles persist across app navigation',
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

      // Create two tiles.
      await tiles.insert(title: 'Tile A');
      await tiles.insert(title: 'Tile B');
      await pumpFrames($);

      // Verify both exist in DB.
      final all = await tiles.getAll();
      expect(all, hasLength(2));

      // Navigate to parent dashboard.
      await $.tester.tap(find.byTooltip('Eltern-Bereich'));
      await pumpFrames($);

      // Tiles should still be in DB while in parent area.
      final inParent = await tiles.getAll();
      expect(inParent, hasLength(2));

      // Navigate back via back button in app bar.
      // ignore: deprecated_member_use -- $.native is the stable API for now.
      await $.native.pressBack();
      await pumpFrames($);

      // Tiles still there.
      final afterBack = await tiles.getAll();
      expect(afterBack, hasLength(2));
    },
  );
}

class _AlwaysAuth extends ParentAuth {
  @override
  bool build() => true;
}
