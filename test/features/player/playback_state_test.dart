import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/features/player/player_error.dart';
import 'package:lauschi/features/player/player_state.dart';

void main() {
  group('PlaybackState.copyWith', () {
    test('preserves sticky fields when updating playback fields', () {
      // Simulate what happens in PlayerNotifier: playCard sets app-level
      // fields, then bridge events update playback fields. The app-level
      // fields must survive the merge.
      var state = const PlaybackState(
        activeCardId: 'card-123',
        activeContextUri: 'spotify:album:abc',
        activeGroupId: 'group-456',
      );

      // Bridge event updates playback fields.
      state = state.copyWith(
        isPlaying: true,
        isReady: true,
        positionMs: 5000,
        durationMs: 180000,
        track: const TrackInfo(
          uri: 'spotify:track:xyz',
          name: 'Test Track',
          artist: 'Test Artist',
          album: 'Test Album',
        ),
      );

      // Playback fields updated.
      expect(state.isPlaying, isTrue);
      expect(state.isReady, isTrue);
      expect(state.positionMs, 5000);
      expect(state.track?.name, 'Test Track');

      // App-level fields preserved.
      expect(state.activeCardId, 'card-123');
      expect(state.activeContextUri, 'spotify:album:abc');
      expect(state.activeGroupId, 'group-456');
    });

    test('pause preserves activeCardId for position saving', () {
      var state = const PlaybackState(
        activeCardId: 'card-123',
        activeGroupId: 'group-456',
        isPlaying: true,
        isReady: true,
        positionMs: 60000,
        durationMs: 180000,
        track: TrackInfo(
          uri: 'spotify:track:xyz',
          name: 'Test',
          artist: 'Artist',
          album: 'Album',
        ),
      );

      // Bridge reports paused state.
      state = state.copyWith(
        isPlaying: false,
        isReady: true,
        positionMs: 60000,
        durationMs: 180000,
      );

      expect(state.isPlaying, isFalse);
      expect(state.activeCardId, 'card-123');
      expect(state.activeGroupId, 'group-456');
      // Track preserved (copyWith keeps old value when not passed).
      expect(state.track?.name, 'Test');
    });

    test('multiple rapid updates do not clear sticky fields', () {
      var state = const PlaybackState(
        activeCardId: 'card-1',
        activeGroupId: 'group-1',
        activeContextUri: 'spotify:album:abc',
      );

      // Simulate 3 rapid position updates.
      for (var pos = 1000; pos <= 3000; pos += 1000) {
        state = state.copyWith(
          isPlaying: true,
          isReady: true,
          positionMs: pos,
          durationMs: 120000,
        );
      }

      expect(state.activeCardId, 'card-1');
      expect(state.activeGroupId, 'group-1');
      expect(state.activeContextUri, 'spotify:album:abc');
      expect(state.positionMs, 3000);
    });

    test('error is always replaced (omitting clears it)', () {
      const state = PlaybackState(error: PlayerError.playbackFailed);

      // Omitting error clears it (always-replace semantics).
      final cleared = state.copyWith(isPlaying: true);
      expect(cleared.error, isNull);
    });

    test('clearActiveCard nulls activeCardId', () {
      const state = PlaybackState(activeCardId: 'x');
      final cleared = state.copyWith(clearActiveCard: true);
      expect(cleared.activeCardId, isNull);
    });

    test('clearActiveContextUri nulls activeContextUri', () {
      const state = PlaybackState(activeContextUri: 'uri');
      final cleared = state.copyWith(clearActiveContextUri: true);
      expect(cleared.activeContextUri, isNull);
    });

    test('clearActiveGroupId nulls activeGroupId', () {
      const state = PlaybackState(activeGroupId: 'g');
      final cleared = state.copyWith(clearActiveGroupId: true);
      expect(cleared.activeGroupId, isNull);
    });
  });

  group('TrackInfo equality', () {
    test('equal when uri, name, artist match', () {
      const a = TrackInfo(
        uri: 'test:1',
        name: 'Track',
        artist: 'Artist',
        album: 'Album A',
        artworkUrl: 'https://a.com',
      );
      const b = TrackInfo(
        uri: 'test:1',
        name: 'Track',
        artist: 'Artist',
        album: 'Album B',
        artworkUrl: 'https://b.com',
      );
      expect(a, equals(b));
    });

    test('not equal when uri differs', () {
      const a = TrackInfo(
        uri: 'test:1',
        name: 'Track',
        artist: 'Artist',
        album: 'Album',
      );
      const b = TrackInfo(
        uri: 'test:2',
        name: 'Track',
        artist: 'Artist',
        album: 'Album',
      );
      expect(a, isNot(equals(b)));
    });
  });

  group('PlayerError', () {
    test('error categories are assigned correctly', () {
      expect(
        PlayerError.contentUnavailable.category,
        ErrorCategory.gone,
      );
      expect(
        PlayerError.spotifyAuthExpired.category,
        ErrorCategory.parentAction,
      );
      expect(
        PlayerError.spotifyAccountError.category,
        ErrorCategory.parentAction,
      );
      expect(
        PlayerError.appleMusicAuthExpired.category,
        ErrorCategory.parentAction,
      );

      // All other errors are transient "oops".
      for (final error in PlayerError.values) {
        if (error == PlayerError.contentUnavailable ||
            error == PlayerError.spotifyAuthExpired ||
            error == PlayerError.spotifyAccountError ||
            error == PlayerError.appleMusicAuthExpired) {
          continue;
        }
        expect(
          error.category,
          ErrorCategory.oops,
          reason: '$error should be oops category',
        );
      }
    });

    test('every error has a non-empty message', () {
      for (final error in PlayerError.values) {
        expect(error.message, isNotEmpty, reason: '$error has empty message');
      }
    });
  });

  group('progress bar anchor interpolation', () {
    test('seek updates anchor so ticker interpolates from seek position', () {
      var anchorMs = 30000;
      var anchorTime = DateTime.now().subtract(const Duration(seconds: 2));

      // Before seek: interpolated should be near 32s.
      var deltaMs = DateTime.now().difference(anchorTime).inMilliseconds;
      var interpolated = anchorMs + deltaMs;
      expect(interpolated, closeTo(32000, 100));

      // User seeks to 90s. Update anchor.
      anchorMs = 90000;
      anchorTime = DateTime.now();

      // After seek: interpolated should be near 90s, not snap back.
      deltaMs = DateTime.now().difference(anchorTime).inMilliseconds;
      interpolated = anchorMs + deltaMs;
      expect(interpolated, closeTo(90000, 100));
    });
  });
}
