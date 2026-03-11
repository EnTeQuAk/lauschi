import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/features/player/player_state.dart';
import 'package:lauschi/features/player/spotify_player_bridge.dart';

void main() {
  group('SpotifyPlayerBridge', () {
    late SpotifyPlayerBridge bridge;
    late List<PlaybackState> states;
    late StreamSubscription<PlaybackState> sub;

    setUp(() {
      bridge = SpotifyPlayerBridge();
      states = [];
      sub = bridge.stateStream.listen(states.add);
    });

    tearDown(() async {
      await sub.cancel();
      await bridge.dispose();
    });

    test('starts with no device ID and not ready', () {
      expect(bridge.deviceId, isNull);
      expect(bridge.currentState.isReady, isFalse);
    });

    test('stateStream is broadcast (multiple listeners)', () {
      // Verify the stream is broadcast so both the widget and provider
      // can listen independently.
      final s1 = bridge.stateStream.listen((_) {});
      final s2 = bridge.stateStream.listen((_) {});
      addTeardownSafe(s1.cancel);
      addTeardownSafe(s2.cancel);
    });

    test('reconnect without controller is safe (no crash)', () async {
      // Before init(), calling reconnect should be a no-op.
      await bridge.reconnect();
      expect(bridge.deviceId, isNull);
    });

    test('waitForDevice returns null on timeout', () async {
      final result = await bridge.waitForDevice(
        timeout: const Duration(milliseconds: 50),
      );
      expect(result, isNull);
    });

    test('pause/resume/seek without controller are safe', () async {
      // These should not throw when the bridge is uninitialized.
      await bridge.pause();
      await bridge.resume();
      await bridge.nextTrack();
      await bridge.prevTrack();
      await bridge.seek(5000);
    });
  });
}

/// Cancel a subscription in teardown without propagating errors.
void addTeardownSafe(Future<void> Function() fn) {
  addTearDown(() async {
    try {
      await fn();
    } on Object {
      // Ignore errors during cleanup.
    }
  });
}
