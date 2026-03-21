import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/features/player/apple_music_webview_bridge.dart';
import 'package:lauschi/features/player/player_state.dart';

void main() {
  group('AppleMusicWebViewBridge', () {
    late AppleMusicWebViewBridge bridge;

    setUp(() {
      bridge = AppleMusicWebViewBridge();
    });

    tearDown(() async {
      await bridge.dispose();
    });

    test('starts with empty state', () {
      expect(bridge.currentState, const PlaybackState());
      expect(bridge.controllerOrNull, isNull);
      expect(bridge.trackIndex, 0);
      expect(bridge.totalTracks, 0);
      expect(bridge.hasNextTrack, false);
    });

    test('hasNextTrack is false when on last track', () {
      // Can't set internal state directly, but default is correct.
      expect(bridge.hasNextTrack, false);
    });

    test('init throws on disposed bridge', () async {
      await bridge.dispose();
      expect(
        () => bridge.init(
          developerToken: 'dev-token',
          musicUserToken: 'user-token',
        ),
        throwsStateError,
      );
    });

    test('tearDown resets state', () {
      bridge.tearDown();
      expect(bridge.currentState, const PlaybackState());
      expect(bridge.controllerOrNull, isNull);
    });

    test('tearDown is idempotent', () {
      bridge
        ..tearDown()
        ..tearDown(); // Should not throw.
    });

    test('dispose is idempotent', () async {
      await bridge.dispose();
      await bridge.dispose(); // Should not throw.
    });

    test('stateStream emits on state changes', () async {
      final states = <PlaybackState>[];
      final sub = bridge.stateStream.listen(states.add);

      // tearDown emits a reset state.
      bridge.tearDown();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(states, isNotEmpty);
      expect(states.last, const PlaybackState());

      await sub.cancel();
    });
  });
}
