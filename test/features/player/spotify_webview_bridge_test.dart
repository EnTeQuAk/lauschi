import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/features/player/player_state.dart';
import 'package:lauschi/features/player/spotify_webview_bridge.dart';

void main() {
  group('SpotifyWebViewBridge', () {
    late SpotifyWebViewBridge bridge;
    late List<PlaybackState> states;
    late StreamSubscription<PlaybackState> sub;

    setUp(() {
      bridge = SpotifyWebViewBridge();
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
      final s1 = bridge.stateStream.listen((_) {});
      final s2 = bridge.stateStream.listen((_) {});
      addTearDown(s1.cancel);
      addTearDown(s2.cancel);
    });

    test('reconnect without controller is safe (no crash)', () async {
      await bridge.reconnect();
      expect(bridge.deviceId, isNull);
    });

    test('reconnect clears device state', () async {
      await bridge.reconnect();
      expect(bridge.deviceId, isNull);
      expect(states, isNotEmpty);
      expect(states.last.isReady, isFalse);
    });

    test('waitForDevice returns null on timeout', () async {
      final result = await bridge.waitForDevice(
        timeout: const Duration(milliseconds: 50),
      );
      expect(result, isNull);
    });

    test('pause/resume/seek without controller are safe', () async {
      await bridge.pause();
      await bridge.resume();
      await bridge.nextTrack();
      await bridge.prevTrack();
      await bridge.seek(5000);
    });

    test('JS commands without controller do not emit state changes', () async {
      await bridge.pause();
      await bridge.resume();
      expect(states, isEmpty);
    });

    test('double dispose is safe', () async {
      await bridge.dispose();
    });

    group('tearDown', () {
      test('clears all state', () {
        bridge.tearDown();

        expect(bridge.deviceId, isNull);
        expect(bridge.controllerOrNull, isNull);
        expect(bridge.currentState.isReady, isFalse);
        expect(bridge.currentState.isPlaying, isFalse);
      });

      test('emits reset state', () async {
        bridge.tearDown();
        // Stream delivery is async; yield to let events arrive.
        await Future<void>.delayed(Duration.zero);

        expect(states, isNotEmpty);
        final last = states.last;
        expect(last.isReady, isFalse);
        expect(last.isPlaying, isFalse);
        expect(last.track, isNull);
        expect(last.positionMs, 0);
      });

      test('keeps stateStream open (bridge is reusable)', () async {
        bridge.tearDown();

        var received = false;
        final s = bridge.stateStream.listen((_) => received = true);
        addTearDown(s.cancel);

        // Another tearDown should still emit.
        bridge.tearDown();
        await Future<void>.delayed(Duration.zero);
        expect(received, isTrue);
      });

      test('is idempotent', () {
        bridge
          ..tearDown()
          ..tearDown()
          ..tearDown();

        expect(bridge.deviceId, isNull);
        expect(bridge.controllerOrNull, isNull);
      });

      test('JS commands after tearDown are safe', () async {
        bridge.tearDown();

        await bridge.pause();
        await bridge.resume();
        await bridge.seek(5000);
        await bridge.nextTrack();
        await bridge.prevTrack();
      });

      test('tearDown after dispose is safe', () async {
        await bridge.dispose();
        bridge.tearDown();
      });
    });

    group('init after dispose', () {
      test('throws StateError', () async {
        await bridge.dispose();

        expect(
          () => bridge.init(getValidToken: () async => 'token'),
          throwsStateError,
        );
      });
    });

    group('tearDown → tearDown cycle (no WebView needed)', () {
      test('stream stays alive across multiple tearDown cycles', () async {
        final allStates = <PlaybackState>[];
        final s = bridge.stateStream.listen(allStates.add);
        addTearDown(s.cancel);

        // First tearDown.
        bridge.tearDown();
        await Future<void>.delayed(Duration.zero);
        expect(allStates, isNotEmpty);
        final count1 = allStates.length;

        // Second tearDown still emits (stream alive).
        bridge.tearDown();
        await Future<void>.delayed(Duration.zero);
        expect(allStates.length, greaterThan(count1));
      });

      test('state is reset after each tearDown', () {
        bridge.tearDown();
        expect(bridge.currentState, const PlaybackState());
        expect(bridge.deviceId, isNull);
        expect(bridge.controllerOrNull, isNull);

        bridge.tearDown();
        expect(bridge.currentState, const PlaybackState());
      });
    });
  });
}
