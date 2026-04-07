import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/auth/pin_service.dart';
import 'package:lauschi/core/database/tile_item_repository.dart';
import 'package:lauschi/core/database/tile_repository.dart';
import 'package:lauschi/core/router/app_router.dart';
import 'package:lauschi/core/spotify/spotify_session.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/onboarding/screens/onboarding_provider.dart';
import 'package:lauschi/features/player/player_provider.dart';
import 'package:lauschi/features/player/player_state.dart';

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
/// Returns a list of overrides for the standard "everything is ready"
/// state: onboarding done, parent authenticated. Tests that exercise
/// the redirect gates override these explicitly.
List<Override> _testOverrides({
  bool onboardingDone = true,
  bool parentAuthenticated = true,
}) => [
  spotifySessionProvider.overrideWith(_FakeSession.new),
  playerProvider.overrideWith(_FakePlayerNotifier.new),
  allTileItemsProvider.overrideWith((_) => Stream.value([])),
  ungroupedItemsProvider.overrideWith((_) => Stream.value([])),
  allTilesProvider.overrideWith((_) => Stream.value([])),
  onboardingCompleteProvider.overrideWith(
    () => onboardingDone ? _FakeOnboarding.completed() : _FakeOnboarding.todo(),
  ),
  parentAuthProvider.overrideWith(
    () =>
        parentAuthenticated
            ? _FakeParentAuth.authenticated()
            : _FakeParentAuth.locked(),
  ),
];

/// Returns the current router location for [container]. Used by the
/// route-change context-asserts so we can prove navigation actually
/// happened, not just that some text is visible on screen.
String _currentLocation(ProviderContainer container) {
  return container
      .read(appRouterProvider)
      .routerDelegate
      .currentConfiguration
      .uri
      .path;
}

void main() {
  testWidgets('app starts on kid home route', (tester) async {
    final container = ProviderContainer(overrides: _testOverrides());
    addTearDown(container.dispose);

    await tester.pumpWidget(_buildApp(container));
    await tester.pump();

    expect(
      _currentLocation(container),
      AppRoutes.kidHome,
      reason: 'fresh app with onboarding done lands on /',
    );
    expect(find.text('Meine Hörspiele'), findsOneWidget);
  });

  testWidgets('navigating to /player renders player placeholder', (
    tester,
  ) async {
    final container = ProviderContainer(overrides: _testOverrides());
    addTearDown(container.dispose);

    await tester.pumpWidget(_buildApp(container));
    await tester.pump();

    // Baseline: we start on kid home.
    expect(_currentLocation(container), AppRoutes.kidHome);

    container.read(appRouterProvider).go(AppRoutes.player);
    await tester.pump();
    await tester.pump();

    // Context-assert: route actually changed. Without this, finding
    // a play_arrow icon could match an icon on the kid home screen
    // (false positive).
    expect(_currentLocation(container), AppRoutes.player);

    // Full player renders play/pause button and collapse handle.
    expect(find.byIcon(Icons.play_arrow_rounded), findsAtLeastNWidgets(1));
  });

  testWidgets('navigating to /parent renders parent dashboard', (
    tester,
  ) async {
    final container = ProviderContainer(overrides: _testOverrides());
    addTearDown(container.dispose);

    await tester.pumpWidget(_buildApp(container));
    await tester.pump();

    expect(_currentLocation(container), AppRoutes.kidHome);

    container.read(appRouterProvider).go(AppRoutes.parentDashboard);
    await tester.pump();
    await tester.pump();

    // Context-assert: route actually changed AND we're not on the
    // PIN gate. Both are required because the same provider override
    // could fail in two different ways.
    expect(_currentLocation(container), AppRoutes.parentDashboard);

    // Parent dashboard renders with settings title.
    expect(find.text('Einstellungen'), findsAtLeastNWidgets(1));
  });

  // ── PIN gate ───────────────────────────────────────────────────────

  testWidgets(
    'navigating to /parent while not authenticated redirects to /pin',
    (tester) async {
      // Security-critical: this is the gate that keeps kids out of
      // parent mode. The 3 tests above all override `parentAuthProvider`
      // to true, so they bypass this gate entirely. This test exercises
      // the actual redirect.
      final container = ProviderContainer(
        overrides: _testOverrides(parentAuthenticated: false),
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(_buildApp(container));
      await tester.pump();

      container.read(appRouterProvider).go(AppRoutes.parentDashboard);
      await tester.pump();
      await tester.pump();

      expect(
        _currentLocation(container),
        AppRoutes.pinEntry,
        reason:
            '/parent must redirect to /pin when parentAuthProvider '
            'returns false',
      );
    },
  );

  testWidgets(
    'navigating to a parent subroute while not authenticated also redirects',
    (tester) async {
      // Verifies the redirect uses startsWith('/parent'), not exact
      // match. If someone changed the redirect logic to == '/parent',
      // /parent/tiles would slip through. This test catches that
      // regression by attempting to navigate directly to a subroute.
      final container = ProviderContainer(
        overrides: _testOverrides(parentAuthenticated: false),
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(_buildApp(container));
      await tester.pump();

      container.read(appRouterProvider).go(AppRoutes.parentSettings);
      await tester.pump();
      await tester.pump();

      expect(
        _currentLocation(container),
        AppRoutes.pinEntry,
        reason: '/parent/* subroutes must also be PIN-gated',
      );
    },
  );

  // ── Onboarding gate ────────────────────────────────────────────────

  testWidgets(
    'fresh app without completed onboarding redirects to /onboarding',
    (tester) async {
      // First-run UX: a brand new install with no preferences set
      // should drop the user into onboarding, not into the empty kid
      // home screen.
      final container = ProviderContainer(
        overrides: _testOverrides(onboardingDone: false),
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(_buildApp(container));
      await tester.pump();
      await tester.pump();

      expect(
        _currentLocation(container),
        AppRoutes.onboarding,
        reason: 'fresh install must land on /onboarding',
      );
    },
  );

  testWidgets(
    'navigating to /onboarding after completion redirects back to /',
    (tester) async {
      // Returning user case: if onboarding is done and the user
      // somehow navigates to /onboarding (deep link, back stack), the
      // redirect should send them home rather than show the welcome
      // flow again.
      final container = ProviderContainer(overrides: _testOverrides());
      addTearDown(container.dispose);

      await tester.pumpWidget(_buildApp(container));
      await tester.pump();

      expect(_currentLocation(container), AppRoutes.kidHome);

      container.read(appRouterProvider).go(AppRoutes.onboarding);
      await tester.pump();
      await tester.pump();

      expect(
        _currentLocation(container),
        AppRoutes.kidHome,
        reason: '/onboarding with onboardingDone=true must redirect to /',
      );
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
  _FakeOnboarding._(this._value);
  factory _FakeOnboarding.completed() => _FakeOnboarding._(true);
  factory _FakeOnboarding.todo() => _FakeOnboarding._(false);

  final bool _value;

  @override
  bool build() => _value;
}

class _FakeParentAuth extends ParentAuth {
  _FakeParentAuth._(this._value);
  factory _FakeParentAuth.authenticated() => _FakeParentAuth._(true);
  factory _FakeParentAuth.locked() => _FakeParentAuth._(false);

  final bool _value;

  @override
  bool build() => _value;
}
