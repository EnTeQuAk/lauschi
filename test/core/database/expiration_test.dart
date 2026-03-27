import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/database/app_database.dart';
import 'package:lauschi/core/database/tile_item_repository.dart';

/// Minimal TileItem for testing expiration logic.
TileItem _item({
  String id = 'test-item',
  DateTime? availableUntil,
  DateTime? markedUnavailable,
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
    markedUnavailable: markedUnavailable,
    groupId: groupId,
  );
}

void main() {
  // isItemExpired only checks markedUnavailable (runtime flag).
  // ARD's endDate (stored as availableUntil) is NOT a reliable content
  // removal signal. Audio URLs remain on CDN well past endDate.
  group('isItemExpired', () {
    test('returns false when markedUnavailable is null', () {
      expect(isItemExpired(_item()), isFalse);
    });

    test('returns false even when availableUntil is in the past', () {
      // availableUntil alone does NOT make an item expired.
      // Content often remains playable past endDate.
      final item = _item(
        availableUntil: DateTime.now().subtract(const Duration(hours: 1)),
      );
      expect(isItemExpired(item), isFalse);
    });

    test('returns true when markedUnavailable is set', () {
      final item = _item(markedUnavailable: DateTime.now());
      expect(isItemExpired(item), isTrue);
    });

    test('returns true when both markedUnavailable and availableUntil set', () {
      final item = _item(
        availableUntil: DateTime.now().subtract(const Duration(days: 1)),
        markedUnavailable: DateTime.now(),
      );
      expect(isItemExpired(item), isTrue);
    });
  });

  group('tileProgressProvider excludes expired items', () {
    // These are pure-logic tests. The provider just iterates items and
    // filters with isItemExpired. We test the filtering logic directly.

    test('items marked unavailable are excluded from counts', () {
      final items = [
        _item(
          id: '1',
          groupId: 'tile-a',
          markedUnavailable: DateTime.now(), // confirmed unavailable
        ),
        _item(
          id: '2',
          groupId: 'tile-a',
          isHeard: true,
        ),
        _item(
          id: '3',
          groupId: 'tile-a',
        ),
      ];

      // Simulate what tileProgressProvider does:
      final result = <String, ({int total, int heard})>{};
      for (final item in items) {
        final tid = item.groupId;
        if (tid == null) continue;
        if (isItemExpired(item)) continue;
        final prev = result[tid] ?? (total: 0, heard: 0);
        result[tid] = (
          total: prev.total + 1,
          heard: prev.heard + (item.isHeard ? 1 : 0),
        );
      }

      expect(result['tile-a']!.total, 2);
      expect(result['tile-a']!.heard, 1);
    });

    test('items with past availableUntil are NOT excluded', () {
      // availableUntil is informational only (e.g. "Noch 2 Tage" badge).
      // Only markedUnavailable triggers exclusion.
      final items = [
        _item(
          id: '1',
          groupId: 'tile-a',
          availableUntil: DateTime.now().subtract(const Duration(days: 5)),
        ),
        _item(
          id: '2',
          groupId: 'tile-a',
        ),
      ];

      final result = <String, ({int total, int heard})>{};
      for (final item in items) {
        final tid = item.groupId;
        if (tid == null) continue;
        if (isItemExpired(item)) continue;
        final prev = result[tid] ?? (total: 0, heard: 0);
        result[tid] = (
          total: prev.total + 1,
          heard: prev.heard + (item.isHeard ? 1 : 0),
        );
      }

      // Both items counted, even the one with past availableUntil.
      expect(result['tile-a']!.total, 2);
    });

    test('tile with all items marked unavailable has no entry', () {
      final items = [
        _item(
          id: '1',
          groupId: 'tile-a',
          markedUnavailable: DateTime.now(),
        ),
        _item(
          id: '2',
          groupId: 'tile-a',
          markedUnavailable: DateTime.now(),
        ),
      ];

      final result = <String, ({int total, int heard})>{};
      for (final item in items) {
        final tid = item.groupId;
        if (tid == null) continue;
        if (isItemExpired(item)) continue;
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
