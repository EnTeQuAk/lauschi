import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/features/player/player_provider.dart';
import 'package:lauschi/features/player/player_state.dart';
import 'package:lauschi/features/player/screens/player_screen.dart';
import 'package:lauschi/features/player/spotify_player_bridge.dart';

import '../../helpers/fake_player_notifier.dart';

void main() {
  group('ContentUnavailableScreen', () {
    testWidgets('shows bird emoji and message for expired content', (
      tester,
    ) async {
      final fakeNotifier = FakePlayerNotifier(
        const PlaybackState(
          error: 'Diese Geschichte ist leider nicht mehr verfügbar',
        ),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            playerProvider.overrideWith(() => fakeNotifier),
            spotifyPlayerBridgeProvider.overrideWithValue(
              SpotifyPlayerBridge(),
            ),
          ],
          child: const MaterialApp(home: PlayerScreen()),
        ),
      );

      expect(find.text('🐦'), findsOneWidget);
      expect(find.textContaining('weggeflogen'), findsOneWidget);
      expect(find.textContaining('tolle Geschichten'), findsOneWidget);
      expect(find.text('Zurück'), findsOneWidget);
    });

    testWidgets('shows bird screen for content_unavailable error', (
      tester,
    ) async {
      final fakeNotifier = FakePlayerNotifier(
        const PlaybackState(error: 'content_unavailable'),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            playerProvider.overrideWith(() => fakeNotifier),
            spotifyPlayerBridgeProvider.overrideWithValue(
              SpotifyPlayerBridge(),
            ),
          ],
          child: const MaterialApp(home: PlayerScreen()),
        ),
      );

      expect(find.text('🐦'), findsOneWidget);
    });

    testWidgets('back button clears error and pops', (tester) async {
      final fakeNotifier = FakePlayerNotifier(
        const PlaybackState(
          error: 'Diese Geschichte ist leider nicht mehr verfügbar',
        ),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            playerProvider.overrideWith(() => fakeNotifier),
            spotifyPlayerBridgeProvider.overrideWithValue(
              SpotifyPlayerBridge(),
            ),
          ],
          child: MaterialApp(
            home: const Scaffold(body: Text('Home')),
            routes: {
              '/player': (_) => const PlayerScreen(),
            },
          ),
        ),
      );

      // Navigate to player.
      tester.state<NavigatorState>(find.byType(Navigator)).pushNamed(
        '/player',
      );
      await tester.pumpAndSettle();

      expect(find.text('🐦'), findsOneWidget);

      // Tap back button.
      await tester.tap(find.text('Zurück'));
      await tester.pumpAndSettle();

      expect(fakeNotifier.clearErrorCalled, isTrue);
      expect(find.text('Home'), findsOneWidget);
    });

    testWidgets('does not show bird screen when no error', (tester) async {
      final fakeNotifier = FakePlayerNotifier(
        const PlaybackState(
          isReady: true,
          isPlaying: true,
          durationMs: 60000,
          positionMs: 5000,
          track: TrackInfo(
            uri: 'test:uri',
            name: 'Test Track',
            artist: 'Test',
            album: 'Test Album',
          ),
        ),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            playerProvider.overrideWith(() => fakeNotifier),
            spotifyPlayerBridgeProvider.overrideWithValue(
              SpotifyPlayerBridge(),
            ),
          ],
          child: const MaterialApp(home: PlayerScreen()),
        ),
      );

      // Should show normal player, not bird screen.
      expect(find.text('🐦'), findsNothing);
      expect(find.text('Test Track'), findsOneWidget);
    });
  });
}
