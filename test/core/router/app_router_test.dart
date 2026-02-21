import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/auth/pin_service.dart';
import 'package:lauschi/core/database/card_repository.dart';
import 'package:lauschi/core/database/group_repository.dart';
import 'package:lauschi/core/router/app_router.dart';
import 'package:lauschi/core/spotify/spotify_auth_provider.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/onboarding/screens/onboarding_provider.dart';
import 'package:lauschi/features/player/player_provider.dart';
import 'package:lauschi/features/player/player_state.dart';
import 'package:lauschi/features/player/spotify_player_bridge.dart';

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

/// Override providers that require platform channels or async init.
List<Override> get _testOverrides => [
  spotifyAuthProvider.overrideWith(_FakeAuthNotifier.new),
  spotifyPlayerBridgeProvider.overrideWithValue(SpotifyPlayerBridge()),
  playerProvider.overrideWith(_FakePlayerNotifier.new),
  allCardsProvider.overrideWith((_) => Stream.value([])),
  ungroupedCardsProvider.overrideWith((_) => Stream.value([])),
  allGroupsProvider.overrideWith((_) => Stream.value([])),
  // Skip onboarding in tests
  onboardingCompleteProvider.overrideWith(_FakeOnboarding.new),
  // Skip PIN gate
  parentAuthProvider.overrideWith(_FakeParentAuth.new),
];

void main() {
  testWidgets('app starts on kid home route', (tester) async {
    final container = ProviderContainer(overrides: _testOverrides);
    addTearDown(container.dispose);

    await tester.pumpWidget(_buildApp(container));
    await tester.pump();

    expect(find.text('Meine Hörspiele'), findsOneWidget);
  });

  testWidgets('navigating to /player renders player placeholder', (
    tester,
  ) async {
    final container = ProviderContainer(overrides: _testOverrides);
    addTearDown(container.dispose);

    await tester.pumpWidget(_buildApp(container));
    await tester.pump();

    container.read(appRouterProvider).go(AppRoutes.player);
    await tester.pump();
    await tester.pump();

    // Full player renders play/pause button and collapse handle
    expect(find.byIcon(Icons.play_arrow_rounded), findsAtLeastNWidgets(1));
  });

  testWidgets('navigating to /parent renders parent dashboard placeholder', (
    tester,
  ) async {
    final container = ProviderContainer(overrides: _testOverrides);
    addTearDown(container.dispose);

    await tester.pumpWidget(_buildApp(container));
    await tester.pump();

    container.read(appRouterProvider).go(AppRoutes.parentDashboard);
    await tester.pump();
    await tester.pump();

    // Parent dashboard renders with settings title
    expect(find.text('Einstellungen'), findsAtLeastNWidgets(1));
  });
}

class _FakeAuthNotifier extends SpotifyAuthNotifier {
  @override
  SpotifyAuthState build() => const AuthUnauthenticated();
}

class _FakePlayerNotifier extends PlayerNotifier {
  @override
  PlaybackState build() => const PlaybackState();
}

class _FakeOnboarding extends OnboardingComplete {
  @override
  bool build() => true; // Already completed
}

class _FakeParentAuth extends ParentAuth {
  @override
  bool build() => true; // Already authenticated for test navigation
}
