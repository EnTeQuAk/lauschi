import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/auth/pin_service.dart';
import 'package:lauschi/core/connectivity/connectivity_provider.dart';
import 'package:lauschi/core/database/tile_item_repository.dart';
import 'package:lauschi/core/database/tile_repository.dart';
import 'package:lauschi/core/router/app_router.dart';
import 'package:lauschi/core/spotify/spotify_session.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/onboarding/screens/onboarding_provider.dart';
import 'package:lauschi/features/player/player_error.dart';
import 'package:lauschi/features/player/player_provider.dart';
import 'package:lauschi/features/player/player_state.dart';
import 'package:lauschi/features/player/widgets/player_error_dialog.dart';

import 'fake_player_notifier.dart';

/// Full app shell with [PlayerErrorHost] mounted above the router,
/// exactly as app.dart wires it. Error-dialog tests drive it through
/// the provider and assert on the root-navigator dialog.
Widget buildErrorHostApp(ProviderContainer container) {
  return UncontrolledProviderScope(
    container: container,
    child: Consumer(
      builder: (context, ref, _) {
        final router = ref.watch(appRouterProvider);
        return MaterialApp.router(
          theme: buildAppTheme(),
          routerConfig: router,
          builder:
              (context, child) =>
                  PlayerErrorHost(child: child ?? const SizedBox.shrink()),
        );
      },
    ),
  );
}

/// Container with an empty catalog and all platform-channel providers
/// faked, so the kid home renders and the player screen is reachable.
ProviderContainer errorHostContainer(FakePlayerNotifier notifier) {
  return ProviderContainer(
    overrides: [
      playerProvider.overrideWith(() => notifier),
      spotifySessionProvider.overrideWith(FakeSpotifySession.new),
      onboardingCompleteProvider.overrideWith(FakeOnboarding.new),
      parentAuthProvider.overrideWith(FakeParentAuth.new),
      isOnlineProvider.overrideWith(FakeOnline.new),
      allTileItemsProvider.overrideWith((_) => Stream.value(const [])),
      ungroupedItemsProvider.overrideWith((_) => Stream.value(const [])),
      allTilesProvider.overrideWith((_) => Stream.value(const [])),
    ],
  );
}

/// Pump the shell to a settled first frame.
Future<void> pumpErrorHostApp(
  WidgetTester tester,
  ProviderContainer container,
) async {
  await tester.pumpWidget(buildErrorHostApp(container));
  await tester.pump();
  await tester.pump();
}

/// Raise a player error and pump until the dialog is on screen.
Future<void> raisePlayerError(
  WidgetTester tester,
  FakePlayerNotifier notifier,
  PlayerError error,
) async {
  notifier.setError(error);
  await tester.pump(); // ref.listen fires
  await tester.pump(); // post-frame callback shows the dialog
  await tester.pump(); // dialog builds
}

const playingState = PlaybackState(
  isReady: true,
  track: TrackInfo(
    uri: 'test:uri',
    name: 'Test Track',
    artist: 'Test',
    album: 'Test Album',
  ),
);

class FakeSpotifySession extends SpotifySession {
  @override
  SpotifySessionState build() => const SpotifyUnauthenticated();
}

class FakeOnboarding extends OnboardingComplete {
  @override
  bool build() => true;
}

class FakeParentAuth extends ParentAuth {
  @override
  bool build() => true;

  @override
  void touch() {}
}

class FakeOnline extends IsOnline {
  @override
  bool build() => true;
}
