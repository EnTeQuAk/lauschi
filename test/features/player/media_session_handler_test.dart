import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/features/player/media_session_handler.dart';
import 'package:lauschi/features/player/player_state.dart' as app;

const _track = app.TrackInfo(
  uri: 'ard:item:1',
  name: 'Folge 7',
  artist: 'Die drei ???',
  album: 'Folge 7',
);

void main() {
  group('mediaItemMetadataEquals', () {
    MediaItem item({String id = 'a', String title = 'T', int durMs = 1000}) =>
        MediaItem(
          id: id,
          title: title,
          duration: Duration(milliseconds: durMs),
        );

    test('equal for identical metadata', () {
      expect(mediaItemMetadataEquals(item(), item()), isTrue);
    });

    test('differs when the duration changes (same id)', () {
      // A duration discovered mid-play keeps the id; the notification
      // must still update, which MediaItem.== (id-only) would miss.
      expect(
        mediaItemMetadataEquals(item(durMs: 0), item(durMs: 1800000)),
        isFalse,
      );
    });

    test('differs when the title changes', () {
      expect(
        mediaItemMetadataEquals(item(title: 'A'), item(title: 'B')),
        isFalse,
      );
    });
  });

  group('updateFromAppState notification churn', () {
    test(
      're-emits metadata only when it changes, not per position tick',
      () async {
        final handler = MediaSessionHandler();
        final emitted = <MediaItem?>[];
        final sub = handler.mediaItem.listen(emitted.add);
        addTearDown(sub.cancel);

        // Same track, three position ticks.
        for (final pos in [1000, 2000, 3000]) {
          handler.updateFromAppState(
            const app.PlaybackState(
              track: _track,
              isPlaying: true,
              isReady: true,
              durationMs: 1800000,
            ).copyWith(positionMs: pos),
          );
        }
        // The BehaviorSubject delivers its events asynchronously.
        await Future<void>.delayed(Duration.zero);

        expect(
          emitted.whereType<MediaItem>().toList(),
          hasLength(1),
          reason: 'identical metadata must not re-push on every tick',
        );

        // A real track change emits again.
        handler.updateFromAppState(
          const app.PlaybackState(
            track: app.TrackInfo(uri: 'ard:item:2', name: 'Folge 8'),
            isPlaying: true,
            isReady: true,
            durationMs: 1700000,
          ),
        );
        await Future<void>.delayed(Duration.zero);

        expect(
          emitted.whereType<MediaItem>().toList(),
          hasLength(2),
          reason: 'a new track updates the notification',
        );
      },
    );
  });
}
