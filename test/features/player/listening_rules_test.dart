import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/database/app_database.dart';
import 'package:lauschi/features/player/listening_rules.dart';

final _item = TileItem(
  id: 'item',
  title: 'Folge 1',
  cardType: 'album',
  provider: 'spotify',
  providerUri: 'spotify:album:1',
  isHeard: false,
  createdAt: DateTime(2026),
  totalTracks: 0,
  durationMs: 0,
  lastTrackNumber: 0,
  lastPositionMs: 0,
  lastElapsedMs: 0,
);

const _minute = 60000;

/// Progress with [remainingMs] left of a [durationMs] long item.
///
/// [coveredMs] defaults to a listen from the start up to there.
PlaybackProgress _left(
  int remainingMs, {
  required int durationMs,
  int? coveredMs,
}) => (
  trackNumber: 3,
  isLastTrack: false,
  positionMs: 0,
  trackDurationMs: 0,
  elapsedMs: durationMs - remainingMs,
  durationMs: durationMs,
  coveredMs: coveredMs ?? durationMs - remainingMs,
);

void main() {
  group('isStartedEnough', () {
    test('a short peek is not a start', () {
      expect(isStartedEnough(const Duration(seconds: 19)), isFalse);
    });

    test('20 seconds of play is', () {
      expect(isStartedEnough(const Duration(seconds: 20)), isTrue);
    });
  });

  group('isFinishedEnough with a known duration', () {
    // Cases from where kids left episodes in 2026-09 (Sentry logs, one
    // family): every considered-done ending had at most 6 % of the album
    // left, the earliest real stop 16.5 %.
    final cases = <(String, int, int, bool)>[
      (
        'Ninjago, next episode tapped with 25 s left',
        25000,
        12 * _minute,
        true,
      ),
      ('Ninjago, let it run out', 0, 12 * _minute, true),
      (
        'Eldrador, skipped song and credits (3.9 %)',
        190000,
        81 * _minute,
        true,
      ),
      (
        'a 12 minute episode with 2 minutes left',
        2 * _minute,
        12 * _minute,
        false,
      ),
      ('stopped early with 16.5 % left', 562000, 3406000, false),
      (
        'a 70 minute album: 4 minutes left is enough',
        4 * _minute,
        70 * _minute,
        true,
      ),
      (
        'a 70 minute album: 5 minutes left is not (10 % would allow 7)',
        5 * _minute,
        70 * _minute,
        false,
      ),
    ];
    for (final (name, remainingMs, durationMs, finished) in cases) {
      test(name, () {
        expect(
          isFinishedEnough(_item, _left(remainingMs, durationMs: durationMs)),
          finished,
        );
      });
    }
  });

  group('isFinishedEnough needs the listen to cover the item', () {
    test('skipping chapters to the end is not hearing it (10-05)', () {
      // Folge 264: "next" through the chapters, the last one ran out.
      final progress = _left(0, durationMs: 12 * _minute, coveredMs: 115000);

      expect(isFinishedEnough(_item, progress), isFalse);
    });

    test('resuming in the credits after a real listen is', () {
      // The listen opened at 11:40 of 12:00 and played the rest.
      final progress = _left(
        0,
        durationMs: 12 * _minute,
        coveredMs: 11 * _minute + 40000 + 20000,
      );

      expect(isFinishedEnough(_item, progress), isTrue);
    });

    test('half the item covered is enough', () {
      final progress = _left(
        0,
        durationMs: 12 * _minute,
        coveredMs: 6 * _minute,
      );

      expect(isFinishedEnough(_item, progress), isTrue);
    });
  });

  group('isFinishedEnough without a known duration', () {
    PlaybackProgress onTrack({required bool last, required int leftMs}) => (
      trackNumber: 2,
      isLastTrack: last,
      positionMs: 180000 - leftMs,
      trackDurationMs: 180000,
      elapsedMs: 0,
      durationMs: 0,
      coveredMs: 0,
    );

    test('the last seconds of the last track count', () {
      expect(
        isFinishedEnough(_item, onTrack(last: true, leftMs: 25000)),
        isTrue,
      );
    });

    test('earlier in the last track does not', () {
      expect(
        isFinishedEnough(_item, onTrack(last: true, leftMs: 60000)),
        isFalse,
      );
    });

    test('the end of an earlier track does not', () {
      expect(
        isFinishedEnough(_item, onTrack(last: false, leftMs: 1000)),
        isFalse,
      );
    });
  });
}
