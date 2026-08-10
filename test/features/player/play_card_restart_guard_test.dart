import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/features/player/player_provider.dart';
import 'package:lauschi/features/player/player_state.dart';

/// Real notifier with a seeded state: card-1 is loaded and playing.
/// playCard itself is NOT overridden, so the test exercises the real
/// entry path.
class _PlayingCard1 extends PlayerNotifier {
  @override
  PlaybackState build() => const PlaybackState(
    activeCardId: 'card-1',
    isPlaying: true,
    isReady: true,
    track: TrackInfo(uri: 'spotify:track:t1', name: 'Folge 7'),
  );
}

void main() {
  test('playCard on the already-playing card is a no-op', () async {
    // A kid tapping the card with the playing badge (or re-presenting
    // an NFC figure) must not tear down the backend: that cuts the
    // audio and resumes from the last saved position, audibly jumping
    // the story backwards. In this bare container any attempt to
    // actually start playback would throw on missing services, so
    // completing without error proves the early return.
    final container = ProviderContainer(
      overrides: [playerProvider.overrideWith(_PlayingCard1.new)],
    );
    addTearDown(container.dispose);
    final before = container.read(playerProvider);

    await container.read(playerProvider.notifier).playCard('card-1');

    expect(
      container.read(playerProvider),
      same(before),
      reason: 'state must be untouched, no teardown or reload',
    );
  });
}
