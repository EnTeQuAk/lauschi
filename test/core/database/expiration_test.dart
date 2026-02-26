import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/database/app_database.dart';
import 'package:lauschi/core/database/tile_item_repository.dart';

/// Minimal TileItem for testing expiration logic.
TileItem _item({
  String id = 'test-item',
  DateTime? availableUntil,
  bool isHeard = false,
  String? groupId,
}) {
  return TileItem(
    id: id,
    title: 'Test Episode',
    cardType: 'episode',
    provider: 'ard_audiothek',
    providerUri: 'ard:item:$id',
    sortOrder: 0,
    isHeard: isHeard,
    totalTracks: 0,
    lastTrackNumber: 0,
    lastPositionMs: 0,
    durationMs: 0,
    createdAt: DateTime.now(),
    availableUntil: availableUntil,
    groupId: groupId,
  );
}

void main() {
  group('isItemExpired', () {
    test('returns false when availableUntil is null (permanent content)', () {
      final item = _item();
      expect(isItemExpired(item), isFalse);
    });

    test('returns false when availableUntil is in the future', () {
      final item = _item(
        availableUntil: DateTime.now().add(const Duration(days: 30)),
      );
      expect(isItemExpired(item), isFalse);
    });

    test('returns true when availableUntil is in the past', () {
      final item = _item(
        availableUntil: DateTime.now().subtract(const Duration(hours: 1)),
      );
      expect(isItemExpired(item), isTrue);
    });

    test('uses provided now parameter for deterministic testing', () {
      final fixedNow = DateTime(2025, 6, 1);
      final item = _item(availableUntil: DateTime(2025, 5, 31));

      expect(isItemExpired(item, now: fixedNow), isTrue);
      expect(isItemExpired(item, now: DateTime(2025, 5, 30)), isFalse);
    });
  });

  group('tileProgressProvider excludes expired items', () {
    // These are pure-logic tests. The provider just iterates items and
    // filters with isItemExpired. We test the filtering logic directly.

    test('expired items are excluded from counts', () {
      final now = DateTime(2025, 6, 1);
      final items = [
        _item(
          id: '1',
          groupId: 'tile-a',
          availableUntil: DateTime(2025, 5, 15), // expired
        ),
        _item(
          id: '2',
          groupId: 'tile-a',
          availableUntil: DateTime(2025, 7, 1), // not expired
          isHeard: true,
        ),
        _item(
          id: '3',
          groupId: 'tile-a',
          // null = permanent, not expired
        ),
      ];

      // Simulate what tileProgressProvider does:
      final result = <String, ({int total, int heard})>{};
      for (final item in items) {
        final tid = item.groupId;
        if (tid == null) continue;
        if (isItemExpired(item, now: now)) continue;
        final prev = result[tid] ?? (total: 0, heard: 0);
        result[tid] = (
          total: prev.total + 1,
          heard: prev.heard + (item.isHeard ? 1 : 0),
        );
      }

      expect(result['tile-a']!.total, 2); // 3 items, 1 expired = 2 available
      expect(result['tile-a']!.heard, 1);
    });

    test('tile with all items expired has no entry', () {
      final now = DateTime(2025, 6, 1);
      final items = [
        _item(
          id: '1',
          groupId: 'tile-a',
          availableUntil: DateTime(2025, 5, 1),
        ),
        _item(
          id: '2',
          groupId: 'tile-a',
          availableUntil: DateTime(2025, 5, 15),
        ),
      ];

      final result = <String, ({int total, int heard})>{};
      for (final item in items) {
        final tid = item.groupId;
        if (tid == null) continue;
        if (isItemExpired(item, now: now)) continue;
        final prev = result[tid] ?? (total: 0, heard: 0);
        result[tid] = (
          total: prev.total + 1,
          heard: prev.heard + (item.isHeard ? 1 : 0),
        );
      }

      expect(result['tile-a'], isNull);
    });
  });
}
