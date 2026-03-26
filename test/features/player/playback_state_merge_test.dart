import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/features/player/player_error.dart';
import 'package:lauschi/features/player/player_provider.dart';
import 'package:lauschi/features/player/player_state.dart';
import 'package:lauschi/features/player/spotify_webview_bridge.dart';

void main() {
  group('mergeSpotifyBridgeState (production function)', () {
    test('clears isLoading when bridge reports playing', () {
      const before = PlaybackState(isLoading: true);
      const bridgeState = PlaybackState(
        isPlaying: true,
        isReady: true,
        track: TrackInfo(
          uri: 'spotify:track:123',
          name: 'Track',
          artist: 'Artist',
          album: 'Album',
        ),
      );

      final after = mergeSpotifyBridgeState(before, bridgeState);
      expect(
        after.isLoading,
        isFalse,
        reason: 'isLoading should clear on play',
      );
      expect(after.isPlaying, isTrue);
      expect(after.track, isNotNull);
    });

    test('keeps isLoading true while paused and no error', () {
      const before = PlaybackState(isLoading: true);
      const bridgeState = PlaybackState(isReady: true);

      final after = mergeSpotifyBridgeState(before, bridgeState);
      expect(
        after.isLoading,
        isTrue,
        reason: 'Still loading while not yet playing',
      );
    });

    test('clears isLoading on error', () {
      const before = PlaybackState(isLoading: true);
      const bridgeState = PlaybackState(
        isReady: true,
        error: PlayerError.spotifyNotConnected,
      );

      final after = mergeSpotifyBridgeState(before, bridgeState);
      expect(after.isLoading, isFalse, reason: 'Error should clear loading');
    });

    test('does not re-enable isLoading once cleared', () {
      const before = PlaybackState(isPlaying: true);
      const bridgeState = PlaybackState(isReady: true);

      final after = mergeSpotifyBridgeState(before, bridgeState);
      expect(
        after.isLoading,
        isFalse,
        reason: 'Once loading is cleared, pausing should not re-enable it',
      );
    });

    test('preserves existing error when bridge has none', () {
      const before = PlaybackState(error: PlayerError.playbackFailed);
      const bridgeState = PlaybackState(isPlaying: true, isReady: true);

      final after = mergeSpotifyBridgeState(before, bridgeState);
      expect(after.error, PlayerError.playbackFailed);
    });

    test('bridge error replaces existing error', () {
      const before = PlaybackState(error: PlayerError.playbackFailed);
      const bridgeState = PlaybackState(
        error: PlayerError.spotifyNotConnected,
      );

      final after = mergeSpotifyBridgeState(before, bridgeState);
      expect(after.error, PlayerError.spotifyNotConnected);
    });

    test(
      'omitting isLoading from copyWith keeps it stuck (regression proof)',
      () {
        // Proves the bug: if you forget isLoading in copyWith, it stays true.
        const before = PlaybackState(isLoading: true);
        const bridgeState = PlaybackState(isPlaying: true, isReady: true);

        // Simulate the BROKEN code: copyWith without isLoading.
        final broken = before.copyWith(
          isReady: bridgeState.isReady,
          isPlaying: bridgeState.isPlaying,
          // isLoading intentionally omitted (the bug)
        );
        expect(
          broken.isLoading,
          isTrue,
          reason: 'Without the fix, copyWith keeps old isLoading value',
        );

        // Now the FIXED code: uses the real production function.
        final fixed = mergeSpotifyBridgeState(before, bridgeState);
        expect(
          fixed.isLoading,
          isFalse,
          reason: 'The production merge function clears isLoading',
        );
      },
    );
  });

  group('spotifyJsChannelName', () {
    test('matches what player.html expects', () {
      // The JS in player.html calls SpotifyBridge.postMessage(...).
      // If the Dart channel name doesn't match, messages silently fail.
      expect(spotifyJsChannelName, 'SpotifyBridge');
    });

    test('player.html uses the same channel name', () {
      final html = File('assets/player.html').readAsStringSync();
      // The JS code references SpotifyBridge for postMessage and typeof check.
      expect(html, contains('$spotifyJsChannelName.postMessage'));
      expect(html, contains("typeof $spotifyJsChannelName === 'undefined'"));
    });
  });
}
