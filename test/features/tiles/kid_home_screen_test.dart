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
import 'package:lauschi/core/spotify/spotify_session.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/onboarding/screens/onboarding_provider.dart';
import 'package:lauschi/features/player/player_provider.dart';
import 'package:lauschi/features/player/player_state.dart';

db.TileItem _card({
  required String id,
  required String title,
  String? groupId,
  String providerUri = 'spotify:album:test',
  DateTime? availableUntil,
  DateTime? markedUnavailable,
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
    markedUnavailable: markedUnavailable,
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
    spotifySessionProvider.overrideWith(_FakeSession.new),
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
  testWidgets('shows empty state when no cards exist', (tester) async {
    final container = ProviderContainer(
      overrides: _testOverrides(),
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_buildApp(container));
    await tester.pump();

    expect(find.text('Meine Hörspiele'), findsOneWidget);
  });

  testWidgets('shows cards when ungrouped items exist', (tester) async {
    final cards = [
      _card(id: '1', title: 'TKKG Folge 1'),
      _card(id: '2', title: 'Die drei ??? Folge 1'),
    ];

    final container = ProviderContainer(
      overrides: _testOverrides(ungrouped: cards),
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_buildApp(container));
    await tester.pump();
    await tester.pump();

    expect(find.bySemanticsLabel('TKKG Folge 1'), findsOneWidget);
    expect(find.bySemanticsLabel('Die drei ??? Folge 1'), findsOneWidget);
  });

  testWidgets('tapping a card calls playCard and navigates to player', (
    tester,
  ) async {
    final cards = [_card(id: 'card-1', title: 'Die drei ???')];
    final notifier = _TrackingPlayerNotifier(
      initialState: const PlaybackState(isReady: true),
    );

    final container = ProviderContainer(
      overrides: _testOverrides(
        ungrouped: cards,
        playerNotifier: notifier,
      ),
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_buildApp(container));
    await tester.pump();
    await tester.pump();

    await tester.tap(find.bySemanticsLabel('Die drei ???'));
    // Don't use pumpAndSettle: player screen progress bar ticker
    // runs at 60fps and never settles.
    await tester.pump();
    await tester.pump();

    // playCard was called with the correct ID.
    expect(notifier.playCardCalls, ['card-1']);

    // Navigated to the player screen (back button visible).
    expect(find.byIcon(Icons.chevron_left_rounded), findsOneWidget);
  });

  testWidgets('unavailable tiles are hidden from kids', (tester) async {
    final expiredCard = _card(
      id: 'expired-1',
      title: 'Expired Episode',
      providerUri: 'ard:item:expired',
      markedUnavailable: DateTime(2025), // confirmed unavailable
    );
    final validCard = _card(
      id: 'valid-1',
      title: 'Valid Episode',
      providerUri: 'ard:item:valid',
    );

    final container = ProviderContainer(
      overrides: _testOverrides(ungrouped: [expiredCard, validCard]),
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
    final cards = [_card(id: 'card-1', title: 'Bibi Blocksberg')];
    final notifier = _TrackingPlayerNotifier();
    expect(
      notifier.build().isReady,
      isFalse,
      reason: 'Precondition: player must not be ready',
    );

    final container = ProviderContainer(
      overrides: _testOverrides(
        ungrouped: cards,
        playerNotifier: notifier,
      ),
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_buildApp(container));
    // Don't use pumpAndSettle: connecting indicator animates
    // indefinitely when isReady is false.
    await tester.pump();
    await tester.pump();

    await tester.tap(find.bySemanticsLabel('Bibi Blocksberg'));
    await tester.pump();
    await tester.pump();

    // Should still be on the home screen (no navigation).
    expect(find.text('Meine Hörspiele'), findsOneWidget);

    // playCard was NOT called.
    expect(notifier.playCardCalls, isEmpty);
  });

  testWidgets('now playing bar visible when track is set', (tester) async {
    final cards = [_card(id: '1', title: 'Episode')];

    final container = ProviderContainer(
      overrides: _testOverrides(
        ungrouped: cards,
        playerState: const PlaybackState(
          isReady: true,
          isPlaying: true,
          track: TrackInfo(
            uri: 'spotify:track:abc',
            name: 'Now Playing Test',
            artist: 'Artist',
          ),
          positionMs: 30000,
          durationMs: 120000,
        ),
      ),
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_buildApp(container));
    await tester.pump();

    expect(find.text('Now Playing Test'), findsOneWidget);
  });
}

class _FakeSession extends SpotifySession {
  @override
  SpotifySessionState build() => const SpotifyUnauthenticated();
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
