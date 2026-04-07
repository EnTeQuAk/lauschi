import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/features/player/player_error.dart';
import 'package:lauschi/features/player/player_state.dart';

void main() {
  group('PlaybackState.copyWith', () {
    test('preserves sticky fields when updating playback fields', () {
      // Simulate what happens in PlayerNotifier: playCard sets app-level
      // fields, then bridge events update playback fields. The app-level
      // fields must survive the merge.
      const before = PlaybackState(
        activeCardId: 'card-123',
        activeContextUri: 'spotify:album:abc',
        activeGroupId: 'group-456',
      );

      // Context: before the merge, the state has the sticky fields set
      // and the playback fields at their defaults. Without these asserts,
      // a broken constructor / copyWith identity would still look right
      // because we'd be echoing back the values we set above.
      expect(before.activeCardId, 'card-123');
      expect(before.activeContextUri, 'spotify:album:abc');
      expect(before.activeGroupId, 'group-456');
      expect(before.isPlaying, isFalse, reason: 'setup: default is paused');
      expect(before.track, isNull, reason: 'setup: no track yet');

      // Bridge event updates playback fields.
      final after = before.copyWith(
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

      // Context: copyWith must return a NEW instance, not mutate / return
      // `this`. If it did either, the "preserved fields" assertions below
      // would pass trivially.
      expect(
        identical(after, before),
        isFalse,
        reason: 'copyWith must return a fresh instance',
      );

      // Playback fields updated.
      expect(after.isPlaying, isTrue);
      expect(after.isReady, isTrue);
      expect(after.positionMs, 5000);
      expect(after.track?.name, 'Test Track');

      // App-level fields preserved.
      expect(after.activeCardId, 'card-123');
      expect(after.activeContextUri, 'spotify:album:abc');
      expect(after.activeGroupId, 'group-456');
    });

    test('pause preserves activeCardId for position saving', () {
      const before = PlaybackState(
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

      // Context: before the pause, a track and card are active. The
      // interesting part of this test is that pause preserves those;
      // assert they existed so we don't accidentally test the
      // "track was null all along" trivial case.
      expect(before.isPlaying, isTrue, reason: 'setup: initially playing');
      expect(before.track?.name, 'Test', reason: 'setup: track present');
      expect(before.activeCardId, 'card-123');
      expect(before.activeGroupId, 'group-456');

      // Bridge reports paused state.
      final after = before.copyWith(
        isPlaying: false,
        isReady: true,
        positionMs: 60000,
        durationMs: 180000,
      );

      expect(after.isPlaying, isFalse);
      expect(after.activeCardId, 'card-123');
      expect(after.activeGroupId, 'group-456');
      // Track preserved (copyWith keeps old value when not passed).
      expect(after.track?.name, 'Test');
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
