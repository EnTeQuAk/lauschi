import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/database/app_database.dart';
import 'package:lauschi/features/player/play_session.dart';

TileItem _card({int lastElapsedMs = 0}) => TileItem(
  id: 'card',
  title: 'Folge 231',
  cardType: 'album',
  provider: 'spotify',
  providerUri: 'spotify:album:231',
  isHeard: false,
  createdAt: DateTime(2026),
  totalTracks: 12,
  durationMs: 1853000,
  lastTrackNumber: 0,
  lastPositionMs: 0,
  lastElapsedMs: lastElapsedMs,
);

void main() {
  group('queue', () {
    test('runs writes one after another, in order', () async {
      final session = PlaySession(_card());
      final order = <String>[];
      final slowSave = Completer<void>();

      final save = session.queue(() async {
        await slowSave.future;
        order.add('resume point');
      });
      final finish = session.queue(() async => order.add('finish'));
      slowSave.complete();
      await Future.wait([save, finish]);

      expect(order, ['resume point', 'finish']);
    });

    test('a failed write does not block the next one', () async {
      final session = PlaySession(_card());
      final order = <String>[];

      final failing = session.queue(() async => throw Exception('db'));
      final next = session.queue(() async => order.add('next'));

      await expectLater(failing, throwsException);
      await next;
      expect(order, ['next']);
    });
  });

  group('coveredMs', () {
    test('starts at the resume point the listen opened with', () {
      final session = PlaySession(_card(lastElapsedMs: 600000));

      expect(session.coveredMs, 600000);
    });

    test('grows only while audio plays', () async {
      final session = PlaySession(_card())..resumeClock();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      session.pauseClock();
      final afterPlay = session.coveredMs;
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(afterPlay, greaterThanOrEqualTo(30));
      expect(session.coveredMs, afterPlay, reason: 'paused time is not heard');
    });
  });

  group('resumeAtOf', () {
    test("is the card's stored resume point", () {
      final card = _card().copyWith(
        lastTrackUri: const Value('spotify:track:kapitel6'),
        lastTrackNumber: 6,
        lastPositionMs: 133502,
      );

      expect(resumeAtOf(card), (
        trackUri: 'spotify:track:kapitel6',
        trackNumber: 6,
        positionMs: 133502,
      ));
    });
  });

  group('startPosition', () {
    test('a fresh listen starts at the stored resume point', () {
      final card = _card().copyWith(
        lastTrackUri: const Value('spotify:track:kapitel6'),
        lastTrackNumber: 6,
        lastPositionMs: 133502,
      );

      expect(startPosition(card).positionMs, 133502);
    });

    test('a replay after a pause-finish continues in the credits, not at '
        'the top (10-08: Folge 231 played again from zero)', () {
      final session =
          PlaySession(_card())
            ..finished = true
            ..lastPosition = (
              trackUri: 'spotify:track:credits',
              trackNumber: 12,
              positionMs: 41000,
            );

      final start = startPosition(_card(), continuing: session);

      expect(start, (
        trackUri: 'spotify:track:credits',
        trackNumber: 12,
        positionMs: 41000,
      ));
    });

    test('a replay before any position falls back to the stored point', () {
      final start = startPosition(_card(), continuing: PlaySession(_card()));

      expect(start.positionMs, 0);
    });
  });
}
