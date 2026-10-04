import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/features/player/spotify_webview_bridge.dart';

// The bridge loses its Spotify player in three ways, and only two of them
// leave nobody to restart playback: a page reload after the WebView
// process died, and the SDK going not ready on its own. A reconnect that
// playCard asks for is restarted by playCard, so it must not announce a
// recovery that replays the card a second time.
void main() {
  group('PlayerLossTracker', () {
    test('a reload while playing announces a recovery that was playing', () {
      final tracker =
          PlayerLossTracker()..lost(PlayerLossCause.reload, wasPlaying: true);

      expect(tracker.ready()?.wasPlaying, isTrue);
    });

    test('the SDK going not ready while paused announces it paused', () {
      final tracker =
          PlayerLossTracker()
            ..lost(PlayerLossCause.sdkNotReady, wasPlaying: false);

      final recovery = tracker.ready();
      expect(recovery, isNotNull);
      expect(recovery!.wasPlaying, isFalse);
    });

    test('a requested reconnect announces nothing', () {
      final tracker =
          PlayerLossTracker()
            ..lost(PlayerLossCause.requested, wasPlaying: true);

      expect(tracker.ready(), isNull);
    });

    test('a requested reconnect that falls back to a reload announces '
        'nothing', () {
      final tracker =
          PlayerLossTracker()
            ..lost(PlayerLossCause.requested, wasPlaying: true)
            ..lost(PlayerLossCause.reload, wasPlaying: true);

      expect(tracker.ready(), isNull);
    });

    test('playCard reconnecting after a reload takes the loss over', () {
      final tracker =
          PlayerLossTracker()
            ..lost(PlayerLossCause.reload, wasPlaying: true)
            ..lost(PlayerLossCause.requested, wasPlaying: false);

      expect(tracker.ready(), isNull);
    });

    test('ready without a loss announces nothing', () {
      expect(PlayerLossTracker().ready(), isNull);
    });

    test('one loss announces once', () {
      final tracker =
          PlayerLossTracker()..lost(PlayerLossCause.reload, wasPlaying: true);

      expect([tracker.ready(), tracker.ready()].map((r) => r != null), [
        isTrue,
        isFalse,
      ]);
    });

    test('a second loss keeps whether the first one was playing', () {
      // After the process dies the bridge may report not ready again
      // with playback already stopped. What counts is the state at the
      // moment the player was lost.
      final tracker =
          PlayerLossTracker()
            ..lost(PlayerLossCause.reload, wasPlaying: true)
            ..lost(PlayerLossCause.sdkNotReady, wasPlaying: false);

      expect(tracker.ready()?.wasPlaying, isTrue);
    });

    test('reset forgets a pending loss', () {
      final tracker =
          PlayerLossTracker()
            ..lost(PlayerLossCause.reload, wasPlaying: true)
            ..reset();

      expect(tracker.ready(), isNull);
    });
  });
}
