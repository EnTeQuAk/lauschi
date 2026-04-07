import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/auth/pin_service.dart';
import 'package:lauschi/core/database/app_database.dart';
import 'package:lauschi/core/database/tile_item_repository.dart';
import 'package:lauschi/core/database/tile_repository.dart';
import 'package:lauschi/core/router/app_router.dart';
import 'package:lauschi/core/spotify/spotify_session.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/onboarding/screens/onboarding_provider.dart';
import 'package:lauschi/features/player/player_provider.dart';
import 'package:lauschi/features/player/player_state.dart';

/// Regression tests for the "Kacheln verwalten" screen's layout/semantics
/// bugs that hit production as Sentry issues LAUSCHI-1M (RenderFlex
/// unbounded) and LAUSCHI-1T (`!semantics.parentDataDirty` assertion).
///
/// The breadcrumbs told a clear story: user had tiles AND at least one
/// ungrouped item in the DB, navigated to "Kacheln verwalten", and
/// `_SeriesBody`'s `CustomScrollView` branch put a `DraggableTileGrid`
/// inside a `SliverToBoxAdapter` (unbounded vertical constraints). The
/// grid's internal `Column[Expanded[SingleChildScrollView[...]]]`
/// couldn't lay out with unbounded height → layout assertion. The
/// failed layout left the semantic tree with some
/// `_RenderObjectSemantics` nodes having `parentData == null`, and the
/// Stack at the MaterialApp shell (which is the persistent semantic
/// root across all routes) kept tripping the assertion on every
/// subsequent frame and every subsequent screen.
///
/// 503 events across 10 minutes on screens that don't even use
/// `DraggableTileGrid` (parent-dashboard, kid-home, pin-entry,
/// parent-settings). The fix (shrinkWrap: true in the sliver branch)
/// prevents the root layout failure, and per Flutter's semantic-tree
/// machinery the cascading parentDataDirty errors disappear with it
/// (no corruption = no stale dirty state).
///
/// This test reproduces the exact DB shape that broke production:
/// several tiles plus one ungrouped item. On the buggy code the pump
/// of `/parent/tiles` would throw in layout. On the fixed code it
/// renders cleanly.
void main() {
  late AppDatabase db;
  late TileRepository tiles;
  late TileItemRepository items;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    tiles = TileRepository(db);
    items = TileItemRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  /// Seeds the DB with 3 tiles and 1 ungrouped ARD item, matching the
  /// shape from the original bug report breadcrumbs (user had several
  /// series tiles plus a leftover ungrouped episode).
  Future<void> seedMixedState() async {
    final asterixId = await tiles.insert(title: 'Asterix');
    final bieneMajaId = await tiles.insert(title: 'Biene Maja');
    await tiles.insert(title: 'Checkpod');

    // Attach an episode to one tile so the tiles aren't empty (mirrors
    // the "Asterix, 41 Folgen" etc. display).
    await items.insert(
      title: 'Asterix 01',
      providerUri: 'spotify:album:asterix01',
      cardType: 'episode',
    );
    await items.insertArdEpisode(
      title: 'Biene Maja Folge 1',
      providerUri: 'ard:item:biene1',
      audioUrl: 'https://example.test/biene1.mp3',
      durationMs: 600000,
      tileId: bieneMajaId,
    );

    // The key ingredient: ONE ungrouped item (no tileId assigned).
    await items.insertArdEpisode(
      title: 'König Arthur — unassigned episode',
      providerUri: 'ard:item:konig_arthur_1',
      audioUrl: 'https://example.test/arthur1.mp3',
      durationMs: 900000,
      // tileId intentionally omitted — this is the ungrouped item
      // that triggers the CustomScrollView + SliverToBoxAdapter
      // branch in `_SeriesBody`.
    );

    // Asterix tile has a different parent tile ID assignment via a
    // direct DB update, not through insertArdEpisode, to keep the test
    // focused on the rendering path rather than the insertion API.
    await items.assignToTile(
      itemId:
          (await items.getAll()).firstWhere((i) => i.title == 'Asterix 01').id,
      tileId: asterixId,
    );
  }

  /// Builds the app with overrides that bypass PIN, onboarding,
  /// Spotify auth, and the player — but uses the real Drift database
  /// and the real router so the layout and semantic trees match
  /// production.
  Widget buildApp(ProviderContainer container) {
    return UncontrolledProviderScope(
      container: container,
      child: Consumer(
        builder: (context, ref, _) {
          final router = ref.watch(appRouterProvider);
          return MaterialApp.router(
            theme: buildAppTheme(),
            routerConfig: router,
          );
        },
      ),
    );
  }

  List<Override> buildOverrides() => [
    appDatabaseProvider.overrideWith((ref) => db),
    spotifySessionProvider.overrideWith(_FakeSession.new),
    playerProvider.overrideWith(_FakePlayerNotifier.new),
    onboardingCompleteProvider.overrideWith(_FakeOnboarding.new),
    parentAuthProvider.overrideWith(_FakeParentAuth.new),
  ];

  testWidgets(
    'renders "Kacheln verwalten" with tiles + one ungrouped item '
    '(regression for LAUSCHI-1M/LAUSCHI-1T)',
    (tester) async {
      await seedMixedState();

      final container = ProviderContainer(overrides: buildOverrides());
      addTearDown(container.dispose);

      await tester.pumpWidget(buildApp(container));
      // Let Drift streams propagate: one frame per provider chain.
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      container.read(appRouterProvider).go(AppRoutes.parentManageTiles);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      // The assertion that catches both the layout bug and the
      // semantic cascade: no exception was thrown during the pump.
      expect(
        tester.takeException(),
        isNull,
        reason:
            'Kacheln verwalten should render without layout or semantic '
            'assertions when the DB has tiles AND an ungrouped item',
      );
      expect(find.text('Kacheln verwalten'), findsOneWidget);
      expect(find.text('Nicht zugeordnet (1)'), findsOneWidget);
    },
  );

  testWidgets(
    'repeated navigation into and out of Kacheln verwalten stays clean '
    '(regression for the LAUSCHI-1T cascade across screens)',
    (tester) async {
      await seedMixedState();

      final container = ProviderContainer(overrides: buildOverrides());
      addTearDown(container.dispose);

      await tester.pumpWidget(buildApp(container));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      final router = container.read(appRouterProvider);

      // Ping-pong between parent-dashboard and parent-tiles a handful
      // of times. The original bug had LAUSCHI-1T firing on every frame
      // from the moment the user navigated AWAY from the broken tiles
      // screen, so this exercises the same path.
      for (var i = 0; i < 4; i++) {
        router.go(AppRoutes.parentDashboard);
        for (var j = 0; j < 5; j++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(
          tester.takeException(),
          isNull,
          reason: 'No exception on dashboard (round ${i + 1})',
        );

        router.go(AppRoutes.parentManageTiles);
        for (var j = 0; j < 5; j++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(
          tester.takeException(),
          isNull,
          reason: 'No exception back in Kacheln verwalten (round ${i + 1})',
        );
      }
    },
  );

  testWidgets(
    'bounded mode (no ungrouped items) still renders cleanly — '
    'guards against the fix breaking the unbroken path',
    (tester) async {
      // Tiles but ZERO ungrouped items. This is the pre-bug happy path
      // that always worked; we want to make sure the shrinkWrap fix
      // didn't break it.
      await tiles.insert(title: 'Asterix');
      await tiles.insert(title: 'Biene Maja');

      final container = ProviderContainer(overrides: buildOverrides());
      addTearDown(container.dispose);

      await tester.pumpWidget(buildApp(container));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      container.read(appRouterProvider).go(AppRoutes.parentManageTiles);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(tester.takeException(), isNull);
      expect(find.text('Kacheln verwalten'), findsOneWidget);
      expect(find.text('Nicht zugeordnet (1)'), findsNothing);
    },
  );
}

class _FakeSession extends SpotifySession {
  @override
  SpotifySessionState build() => const SpotifyUnauthenticated();
}

class _FakePlayerNotifier extends PlayerNotifier {
  @override
  PlaybackState build() => const PlaybackState();
}

class _FakeOnboarding extends OnboardingComplete {
  @override
  bool build() => true;
}

class _FakeParentAuth extends ParentAuth {
  @override
  bool build() => true;
}
