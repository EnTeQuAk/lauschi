import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/features/player/player_error.dart';
import 'package:lauschi/features/player/player_state.dart';

/// Reproduces the isLoading merge pattern used by _onBridgeEvent
/// in PlayerNotifier. The bridge state listener must clear isLoading
/// when playback starts, using the same pattern as the direct player
/// and Apple Music listeners.
///
/// The bug: _onBridgeEvent did a copyWith without isLoading, so
/// isLoading stayed true forever even after Spotify started playing.
PlaybackState mergeSpotifyBridgeState(
  PlaybackState current,
  PlaybackState bridgeState,
) {
  return current.copyWith(
    isReady: bridgeState.isReady,
    isPlaying: bridgeState.isPlaying,
    isLoading:
        current.isLoading &&
        !bridgeState.isPlaying &&
        bridgeState.error == null,
    track: bridgeState.track,
    positionMs: bridgeState.positionMs,
    durationMs: bridgeState.durationMs,
    error: bridgeState.error ?? current.error,
  );
}

/// The BROKEN pattern that was in production: no isLoading field.
PlaybackState mergeSpotifyBridgeStateBroken(
  PlaybackState current,
  PlaybackState bridgeState,
) {
  return current.copyWith(
    isReady: bridgeState.isReady,
    isPlaying: bridgeState.isPlaying,
    // BUG: isLoading is missing, so copyWith keeps the old value.
    track: bridgeState.track,
    positionMs: bridgeState.positionMs,
    durationMs: bridgeState.durationMs,
    error: bridgeState.error ?? current.error,
  );
}

void main() {
  group('Spotify bridge state merge: isLoading', () {
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
    });

    test('broken pattern keeps isLoading stuck at true', () {
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

      final after = mergeSpotifyBridgeStateBroken(before, bridgeState);
      // This proves the broken pattern: isLoading stays true.
      expect(
        after.isLoading,
        isTrue,
        reason: 'Without the fix, isLoading stays stuck',
      );
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
  });
}
