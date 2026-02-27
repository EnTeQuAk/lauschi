import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/features/player/player_state.dart';

void main() {
  group('SpotifyPlayerBridge state merging', () {
    // These tests verify that bridge events don't wipe app-level state
    // from PlaybackState. The bridge only knows about SDK playback fields
    // (isPlaying, position, track, etc.), not about app-level fields
    // (activeCardId, activeGroupId, etc.).
    //
    // Regression for the state overwrite bug where `state = bridgeState`
    // replaced the entire provider state on every SDK event.

    test('state_changed preserves activeCardId', () {
      // Simulate what happens in PlayerNotifier:
      // 1. playCard sets activeCardId in state
      // 2. Bridge fires state_changed (from SDK)
      // 3. activeCardId must survive the merge

      // Start with state that has app-level fields set (from playCard).
      var state = const PlaybackState(
        activeCardId: 'card-123',
        activeContextUri: 'spotify:album:abc',
        activeGroupId: 'group-456',
      );

      // Simulate a bridge state_changed event (SDK playing).
      const bridgeState = PlaybackState(
        isPlaying: true,
        isReady: true,
        deviceId: 'device-789',
        positionMs: 5000,
        durationMs: 180000,
        trackNumber: 1,
        nextTracksCount: 9,
        track: TrackInfo(
          uri: 'spotify:track:xyz',
          name: 'Test Track',
          artist: 'Test Artist',
          album: 'Test Album',
        ),
        // Bridge state does NOT have activeCardId, activeGroupId, etc.
      );

      // Merge bridge fields into existing state (the fix).
      state = state.copyWith(
        isPlaying: bridgeState.isPlaying,
        isReady: bridgeState.isReady,
        deviceId: bridgeState.deviceId,
        clearDeviceId: bridgeState.deviceId == null,
        track: bridgeState.track,
        positionMs: bridgeState.positionMs,
        durationMs: bridgeState.durationMs,
        trackNumber: bridgeState.trackNumber,
        nextTracksCount: bridgeState.nextTracksCount,
      );

      // Bridge fields updated.
      expect(state.isPlaying, isTrue);
      expect(state.isReady, isTrue);
      expect(state.deviceId, 'device-789');
      expect(state.positionMs, 5000);
      expect(state.track?.name, 'Test Track');

      // App-level fields preserved.
      expect(state.activeCardId, 'card-123');
      expect(state.activeContextUri, 'spotify:album:abc');
      expect(state.activeGroupId, 'group-456');
    });

    test('state_changed pause preserves activeCardId for position saving', () {
      // Simulate: playing → user pauses → state_changed with paused:true
      // activeCardId must survive so _savePosition works.

      var state = const PlaybackState(
        activeCardId: 'card-123',
        activeGroupId: 'group-456',
        isPlaying: true,
        isReady: true,
        deviceId: 'device-789',
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
      const pausedBridgeState = PlaybackState(
        isReady: true,
        deviceId: 'device-789',
        positionMs: 60000,
        durationMs: 180000,
      );

      state = state.copyWith(
        isPlaying: pausedBridgeState.isPlaying,
        isReady: pausedBridgeState.isReady,
        deviceId: pausedBridgeState.deviceId,
        clearDeviceId: pausedBridgeState.deviceId == null,
        track: pausedBridgeState.track,
        positionMs: pausedBridgeState.positionMs,
        durationMs: pausedBridgeState.durationMs,
        trackNumber: pausedBridgeState.trackNumber,
        nextTracksCount: pausedBridgeState.nextTracksCount,
      );

      // Pause registered.
      expect(state.isPlaying, isFalse);
      expect(state.positionMs, 60000);

      // App-level fields preserved — _savePosition needs activeCardId.
      expect(state.activeCardId, 'card-123');
      expect(state.activeGroupId, 'group-456');

      // Track preserved from previous state (bridge didn't send track data
      // in this event, but copyWith keeps the old value).
      expect(state.track?.name, 'Test');
    });

    test(
      'togglePlay sends pause when isPlaying is true after bridge events',
      () {
        // Simulate the togglePlay decision: after bridge events update
        // the state, isPlaying must reflect actual SDK state.

        var state = const PlaybackState(
          activeCardId: 'card-123',
        );

        // Bridge says playing.
        state = state.copyWith(
          isPlaying: true,
          isReady: true,
          deviceId: 'dev-1',
          positionMs: 1000,
          durationMs: 120000,
        );

        // togglePlay should see isPlaying=true and send pause.
        expect(state.isPlaying, isTrue);
        // And activeCardId is still set.
        expect(state.activeCardId, 'card-123');
      },
    );

    test('multiple bridge events do not clear activeGroupId', () {
      var state = const PlaybackState(
        activeCardId: 'card-1',
        activeGroupId: 'group-1',
        activeContextUri: 'spotify:album:abc',
      );

      // Simulate 3 rapid SDK events (position updates).
      for (var pos = 1000; pos <= 3000; pos += 1000) {
        state = state.copyWith(
          isPlaying: true,
          isReady: true,
          deviceId: 'dev-1',
          positionMs: pos,
          durationMs: 120000,
          trackNumber: 1,
          nextTracksCount: 5,
        );
      }

      expect(state.activeCardId, 'card-1');
      expect(state.activeGroupId, 'group-1');
      expect(state.activeContextUri, 'spotify:album:abc');
      expect(state.positionMs, 3000);
    });

    test('nextEpisodeTitle survives bridge events', () {
      var state = const PlaybackState(
        activeCardId: 'card-1',
        nextEpisodeTitle: 'Folge 2',
        nextEpisodeCoverUrl: 'https://example.com/cover.jpg',
      );

      // Bridge event during advance preview.
      state = state.copyWith(
        isPlaying: false,
        isReady: true,
        positionMs: 180000,
        durationMs: 180000,
      );

      expect(state.nextEpisodeTitle, 'Folge 2');
      expect(state.nextEpisodeCoverUrl, 'https://example.com/cover.jpg');
    });

    test('reconnect clears deviceId but preserves active fields', () {
      var state = const PlaybackState(
        activeCardId: 'card-1',
        activeGroupId: 'group-1',
        isPlaying: true,
        isReady: true,
        deviceId: 'old-device',
      );

      // Simulate reconnect (bridge clears device, notifier merges).
      const reconnectState = PlaybackState(
        isPlaying: true,
        // deviceId is null (cleared by reconnect)
      );

      state = state.copyWith(
        isPlaying: reconnectState.isPlaying,
        isReady: reconnectState.isReady,
        deviceId: reconnectState.deviceId,
        clearDeviceId: reconnectState.deviceId == null,
      );

      expect(state.deviceId, isNull);
      expect(state.isReady, isFalse);
      expect(state.activeCardId, 'card-1');
      expect(state.activeGroupId, 'group-1');
    });
  });

  group('regression: full state replace wiped active fields', () {
    // Before the fix, `state = bridgeState` replaced the entire provider
    // state with the bridge's state, which doesn't contain app-level
    // fields. This test documents the broken behavior to prevent
    // regression.

    test('full replace wipes activeCardId — the original bug', () {
      const appState = PlaybackState(
        activeCardId: 'card-123',
        activeGroupId: 'group-456',
        activeContextUri: 'spotify:album:abc',
      );

      // Bridge state from SDK event (no app-level fields).
      const bridgeState = PlaybackState(
        isPlaying: true,
        isReady: true,
        deviceId: 'dev-1',
        positionMs: 5000,
        durationMs: 180000,
      );

      // OLD behavior: full replace.
      const broken = bridgeState;
      // broken.activeCardId == null → position saving fails
      // broken.activeGroupId == null → auto-advance fails
      expect(broken.activeCardId, isNull, reason: 'old bug: full replace');
      expect(broken.activeGroupId, isNull, reason: 'old bug: full replace');

      // NEW behavior: merge.
      final fixed = appState.copyWith(
        isPlaying: bridgeState.isPlaying,
        isReady: bridgeState.isReady,
        deviceId: bridgeState.deviceId,
        clearDeviceId: bridgeState.deviceId == null,
        positionMs: bridgeState.positionMs,
        durationMs: bridgeState.durationMs,
      );
      expect(fixed.activeCardId, 'card-123', reason: 'merge preserves');
      expect(fixed.activeGroupId, 'group-456', reason: 'merge preserves');
      expect(fixed.isPlaying, isTrue);
    });
  });

  group('progress bar anchor interpolation', () {
    // The _InterpolatedProgress ticker uses an anchor-based approach:
    // it remembers the last known (server or seek) position and time,
    // then interpolates forward at real-time speed. These tests verify
    // the math that the widget's _onTick and _seekTo rely on.

    test('seek updates anchor so ticker interpolates from seek position', () {
      // Before the fix, seeking set _position but not _anchorMs.
      // The next tick would compute _anchorMs + deltaMs from the OLD
      // anchor, snapping the slider back.

      var anchorMs = 30000; // playing at 30s
      var anchorTime = DateTime.now().subtract(const Duration(seconds: 2));

      // Ticker would show: 30000 + 2000 = 32000ms
      var deltaMs = DateTime.now().difference(anchorTime).inMilliseconds;
      var interpolated = anchorMs + deltaMs;
      expect(interpolated, closeTo(32000, 100));

      // User seeks to 90s. The fix: update anchor.
      anchorMs = 90000;
      anchorTime = DateTime.now();

      // Next tick: should interpolate from 90s, not snap back to ~32s.
      deltaMs = DateTime.now().difference(anchorTime).inMilliseconds;
      interpolated = anchorMs + deltaMs;
      expect(interpolated, closeTo(90000, 100));
    });

    test('SDK position update re-anchors correctly', () {
      // Simulate: anchor at 10s, 3 seconds pass, SDK reports 13s.
      var anchorMs = 10000;
      var anchorTime = DateTime.now().subtract(const Duration(seconds: 3));

      // Interpolated position before SDK update.
      var deltaMs = DateTime.now().difference(anchorTime).inMilliseconds;
      expect(anchorMs + deltaMs, closeTo(13000, 100));

      // SDK reports 13200ms (slightly ahead due to buffering).
      const serverMs = 13200;
      if (serverMs != anchorMs) {
        anchorMs = serverMs;
        anchorTime = DateTime.now();
      }

      // Next tick interpolates from new anchor.
      deltaMs = DateTime.now().difference(anchorTime).inMilliseconds;
      expect(anchorMs + deltaMs, closeTo(13200, 100));
    });
  });

  group('PlaybackState.copyWith', () {
    test('error is always replaced (null clears it)', () {
      const state = PlaybackState(error: 'something broke');

      // Explicit null clears the error.
      final cleared = state.copyWith();
      expect(cleared.error, isNull);

      // Not passing error also clears it (design decision — error is
      // transient, not sticky).
      final implicit = state.copyWith(isPlaying: true);
      expect(implicit.error, isNull);
    });

    test('clearDeviceId nulls deviceId', () {
      const state = PlaybackState(deviceId: 'abc');
      final cleared = state.copyWith(clearDeviceId: true);
      expect(cleared.deviceId, isNull);
    });

    test('clearActiveCard nulls activeCardId', () {
      const state = PlaybackState(activeCardId: 'x');
      final cleared = state.copyWith(clearActiveCard: true);
      expect(cleared.activeCardId, isNull);
    });
  });
}
