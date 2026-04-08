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
  String cardType = 'episode',
  int totalTracks = 0,
}) {
  return TileItem(
    id: id,
    title: 'Test Episode',
    cardType: cardType,
    provider: 'ard_audiothek',
    providerUri: 'ard:item:$id',
    sortOrder: 0,
    isHeard: isHeard,
    totalTracks: totalTracks,
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

  group('computeTileProgress', () {
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

      final result = computeTileProgress(items);

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

      final result = computeTileProgress(items);

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

      final result = computeTileProgress(items);

      expect(result['tile-a'], isNull);
    });

    test('ungrouped items are excluded', () {
      final items = [
        _item(id: '1', groupId: 'tile-a'),
        _item(id: '2', groupId: null), // ungrouped
        _item(id: '3', groupId: 'tile-a'),
      ];

      final result = computeTileProgress(items);

      expect(result['tile-a']!.total, 2);
    });

    test('playlist track count is used instead of item count', () {
      final items = [
        _item(
          id: '1',
          groupId: 'tile-a',
          cardType: 'playlist',
          totalTracks: 50, // 50-track playlist
        ),
        _item(id: '2', groupId: 'tile-a'), // regular episode
      ];

      final result = computeTileProgress(items);

      // Playlist contributes 50, episode contributes 1
      expect(result['tile-a']!.total, 51);
    });

    test('playlist with 1 track counts as 1', () {
      final items = [
        _item(
          id: '1',
          groupId: 'tile-a',
          cardType: 'playlist',
          totalTracks: 1, // single-track playlist
        ),
      ];

      final result = computeTileProgress(items);

      expect(result['tile-a']!.total, 1);
    });

    test('multiple tiles have separate counts', () {
      final items = [
        _item(id: '1', groupId: 'tile-a', isHeard: true),
        _item(id: '2', groupId: 'tile-a'),
        _item(id: '3', groupId: 'tile-b', isHeard: true),
        _item(id: '4', groupId: 'tile-b', isHeard: true),
      ];

      final result = computeTileProgress(items);

      expect(result['tile-a']!.total, 2);
      expect(result['tile-a']!.heard, 1);
      expect(result['tile-b']!.total, 2);
      expect(result['tile-b']!.heard, 2);
    });
  });
}
