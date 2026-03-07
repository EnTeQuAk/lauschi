import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/auth/pin_service.dart';
import 'package:lauschi/core/connectivity/connectivity_provider.dart';
import 'package:lauschi/core/database/app_database.dart' as db;
import 'package:lauschi/core/database/tile_item_repository.dart';
import 'package:lauschi/core/database/tile_repository.dart';
import 'package:lauschi/core/router/app_router.dart';
import 'package:lauschi/core/spotify/spotify_auth_provider.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/onboarding/screens/onboarding_provider.dart';
import 'package:lauschi/features/player/player_provider.dart';
import 'package:lauschi/features/player/player_state.dart';
import 'package:lauschi/features/player/spotify_player_bridge.dart';

db.TileItem _card({
  required String id,
  required String title,
  String? groupId,
  String providerUri = 'spotify:album:test',
  DateTime? availableUntil,
}) {
  return db.TileItem(
    id: id,
    title: title,
    cardType: 'album',
    provider: 'spotify',
    providerUri: providerUri,
    groupId: groupId,
    isHeard: false,
    sortOrder: 0,
    createdAt: DateTime(2026),
    totalTracks: 10,
    durationMs: 0,
    lastTrackNumber: 0,
    lastPositionMs: 0,
    availableUntil: availableUntil,
  );
}

Widget _buildApp(ProviderContainer container) {
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

List<Override> _testOverrides({
  PlaybackState playerState = const PlaybackState(isReady: true),
  List<db.TileItem> ungrouped = const [],
  List<db.Tile> tiles = const [],
  _TrackingPlayerNotifier? playerNotifier,
}) {
  return [
    spotifyAuthProvider.overrideWith(_FakeAuth.new),
    spotifyPlayerBridgeProvider.overrideWithValue(SpotifyPlayerBridge()),
    if (playerNotifier != null)
      playerProvider.overrideWith(() => playerNotifier)
    else
      playerProvider.overrideWith(
        () => _TrackingPlayerNotifier(initialState: playerState),
      ),
    allTileItemsProvider.overrideWith((_) => Stream.value(ungrouped)),
    ungroupedItemsProvider.overrideWith((_) => Stream.value(ungrouped)),
    allTilesProvider.overrideWith((_) => Stream.value(tiles)),
    onboardingCompleteProvider.overrideWith(_FakeOnboarding.new),
    parentAuthProvider.overrideWith(_FakeParentAuth.new),
    isOnlineProvider.overrideWith(_FakeOnline.new),
  ];
}

void main() {
  group('kid home screen tile tap', () {
    testWidgets('tapping a tile starts playback and navigates to player', (
      tester,
    ) async {
      final card = _card(id: 'card-1', title: 'Die drei ???');
      final notifier = _TrackingPlayerNotifier(
        initialState: const PlaybackState(isReady: true),
      );

      final container = ProviderContainer(
        overrides: _testOverrides(
          ungrouped: [card],
          playerNotifier: notifier,
        ),
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(_buildApp(container));
      await tester.pumpAndSettle();

      // Tile should be visible (kid mode renders image, find by key).
      final tileFinder = find.byKey(const ValueKey('card-1'));
      expect(tileFinder, findsOneWidget);

      // Tap the tile.
      await tester.tap(tileFinder);
      // Don't use pumpAndSettle — the player screen's progress bar
      // ticker runs at 60fps and never settles.
      await tester.pump();
      await tester.pump();

      // playCard was called with the correct ID.
      expect(notifier.playCardCalls, ['card-1']);

      // Navigated to the player screen (back button visible).
      expect(
        find.byIcon(Icons.chevron_left_rounded),
        findsOneWidget,
      );
    });

    testWidgets('expired tiles are hidden from kids', (
      tester,
    ) async {
      final expiredCard = _card(
        id: 'expired-1',
        title: 'Expired Episode',
        providerUri: 'ard:item:expired',
        availableUntil: DateTime(2025), // expired
      );
      final validCard = _card(
        id: 'valid-1',
        title: 'Valid Episode',
        providerUri: 'ard:item:valid',
      );
      final notifier = _TrackingPlayerNotifier(
        initialState: const PlaybackState(isReady: true),
      );

      final container = ProviderContainer(
        overrides: _testOverrides(
          ungrouped: [expiredCard, validCard],
          playerNotifier: notifier,
        ),
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(_buildApp(container));
      await tester.pump();
      await tester.pump();

      // Expired tile should not be in the tree at all.
      expect(find.byKey(const ValueKey('expired-1')), findsNothing);

      // Valid tile should still be visible.
      expect(find.byKey(const ValueKey('valid-1')), findsOneWidget);
    });

    testWidgets('tapping a tile when not ready does not navigate', (
      tester,
    ) async {
      final card = _card(id: 'card-1', title: 'Bibi Blocksberg');

      final container = ProviderContainer(
        overrides: _testOverrides(
          // isReady: false — Spotify SDK not connected yet.
          playerState: const PlaybackState(),
          ungrouped: [card],
        ),
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(_buildApp(container));
      // Don't use pumpAndSettle — the connecting indicator animates
      // indefinitely when isReady is false.
      await tester.pump();
      await tester.pump();

      final tileFinder = find.byKey(const ValueKey('card-1'));
      expect(tileFinder, findsOneWidget);

      await tester.tap(tileFinder);
      await tester.pump();
      await tester.pump();

      // Should still be on the home screen (no navigation).
      expect(find.text('Meine Hörspiele'), findsOneWidget);
    });
  });
}

// -- Test fakes --

class _FakeAuth extends SpotifyAuthNotifier {
  @override
  SpotifyAuthState build() => const AuthUnauthenticated();
}

class _FakeOnboarding extends OnboardingComplete {
  @override
  bool build() => true;
}

class _FakeParentAuth extends ParentAuth {
  @override
  bool build() => true;
}

class _FakeOnline extends IsOnline {
  @override
  bool build() => true;
}

/// Player notifier that tracks method calls without needing a real bridge.
class _TrackingPlayerNotifier extends PlayerNotifier {
  _TrackingPlayerNotifier({
    this.initialState = const PlaybackState(),
  });

  final PlaybackState initialState;
  final List<String> playCardCalls = [];

  @override
  PlaybackState build() => initialState;

  @override
  Future<void> playCard(String cardId) async {
    playCardCalls.add(cardId);
  }
}
