import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/database/app_database.dart';
import 'package:lauschi/core/database/tile_item_repository.dart';
import 'package:lauschi/features/player/player_provider.dart';

void main() {
  group('shouldSavePosition', () {
    test('false when play time below minimum', () {
      expect(shouldSavePosition(playTimeMs: 10000), isFalse);
    });

    test('true when play time at minimum', () {
      expect(shouldSavePosition(playTimeMs: 20000), isTrue);
    });

    test('true when play time above minimum', () {
      expect(shouldSavePosition(playTimeMs: 60000), isTrue);
    });

    test('respects custom minimum', () {
      expect(
        shouldSavePosition(playTimeMs: 5000, minPlayTimeMs: 3000),
        isTrue,
      );
      expect(
        shouldSavePosition(playTimeMs: 1000, minPlayTimeMs: 3000),
        isFalse,
      );
    });
  });

  group('isNearTrackEnd', () {
    test('false when far from end', () {
      expect(
        isNearTrackEnd(positionMs: 10000, durationMs: 300000),
        isFalse,
      );
    });

    test('true when within threshold of end', () {
      expect(
        isNearTrackEnd(positionMs: 296000, durationMs: 300000),
        isTrue,
      );
    });

    test('false when duration is zero', () {
      expect(
        isNearTrackEnd(positionMs: 0, durationMs: 0),
        isFalse,
      );
    });

    test('respects custom threshold', () {
      expect(
        isNearTrackEnd(
          positionMs: 298000,
          durationMs: 300000,
          thresholdMs: 1000,
        ),
        isFalse,
      );
      expect(
        isNearTrackEnd(
          positionMs: 299500,
          durationMs: 300000,
          thresholdMs: 1000,
        ),
        isTrue,
      );
    });
  });

  group('isAlbumComplete', () {
    test('false when there is a next track', () {
      expect(
        isAlbumComplete(
          hasNextTrack: true,
          positionMs: 299000,
          durationMs: 300000,
        ),
        isFalse,
      );
    });

    test('true on last track near end', () {
      expect(
        isAlbumComplete(
          hasNextTrack: false,
          positionMs: 296000,
          durationMs: 300000,
        ),
        isTrue,
      );
    });

    test('false on last track far from end', () {
      expect(
        isAlbumComplete(
          hasNextTrack: false,
          positionMs: 100000,
          durationMs: 300000,
        ),
        isFalse,
      );
    });
  });

  group('computePlayTime', () {
    test('returns previous when no anchor', () {
      expect(
        computePlayTime(playStartedAt: null, previousPlayTimeMs: 5000),
        5000,
      );
    });

    test('accumulates time from anchor', () {
      final anchor = DateTime.now().subtract(const Duration(seconds: 10));
      final result = computePlayTime(
        playStartedAt: anchor,
        previousPlayTimeMs: 5000,
      );
      // Should be ~15000ms (5000 previous + 10000 elapsed).
      // Allow 500ms tolerance for test execution time.
      expect(result, greaterThan(14500));
      expect(result, lessThan(16000));
    });
  });

  group('handleAlbumCompleted', () {
    late AppDatabase db;
    late TileItemRepository repo;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      repo = TileItemRepository(db);
    });

    tearDown(() => db.close());

    test('marks card as heard', () async {
      final id = await repo.insert(
        title: 'Episode 1',
        providerUri: 'ard:ep1',
        cardType: 'episode',
      );

      await handleAlbumCompleted(repo, cardId: id);

      final card = await repo.getById(id);
      expect(card!.isHeard, isTrue);
    });

    test('skips already-heard cards', () async {
      final id = await repo.insert(
        title: 'Episode 1',
        providerUri: 'ard:ep1',
        cardType: 'episode',
      );
      await repo.markHeard(id);

      // Should not throw or fail.
      await handleAlbumCompleted(repo, cardId: id);

      final card = await repo.getById(id);
      expect(card!.isHeard, isTrue);
    });

    test('clears sibling positions when groupId provided', () async {
      const tileId = 'tile-1';
      // Simulate two episodes in the same group with saved positions.
      final ep1 = await repo.insertArdEpisode(
        title: 'Episode 1',
        providerUri: 'ard:ep1',
        audioUrl: 'https://example.com/1.mp3',
        tileId: tileId,
      );
      final ep2 = await repo.insertArdEpisode(
        title: 'Episode 2',
        providerUri: 'ard:ep2',
        audioUrl: 'https://example.com/2.mp3',
        tileId: tileId,
      );

      // Save positions on both.
      await repo.savePosition(
        itemId: ep1,
        trackUri: 'ard:ep1',
        trackNumber: 1,
        positionMs: 50000,
      );
      await repo.savePosition(
        itemId: ep2,
        trackUri: 'ard:ep2',
        trackNumber: 1,
        positionMs: 30000,
      );

      // Complete ep1. Should clear ep2's position but not ep1's.
      await handleAlbumCompleted(repo, cardId: ep1, groupId: tileId);

      final card1 = await repo.getById(ep1);
      final card2 = await repo.getById(ep2);
      expect(card1!.isHeard, isTrue);
      expect(card1.lastPositionMs, 50000); // ep1 position preserved
      expect(card2!.lastPositionMs, 0); // ep2 position cleared
    });
  });
}
