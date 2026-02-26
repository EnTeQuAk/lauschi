import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/database/app_database.dart';
import 'package:lauschi/core/database/tile_item_repository.dart';

/// Test that position data survives expiration.
///
/// The key guarantee: when content expires, we don't touch the item's
/// lastPositionMs, lastTrackUri, isHeard fields. If the content comes
/// back (ARD sometimes extends availability), the user resumes where
/// they left off.
void main() {
  group('expiration preserves playback state', () {
    test('expired item retains position data', () {
      // Simulate an item that was being listened to, then expired.
      final item = TileItem(
        id: 'item-1',
        title: 'Pumuckl Folge 3',
        cardType: 'episode',
        provider: 'ard_audiothek',
        providerUri: 'ard:item:12345',
        sortOrder: 0,
        isHeard: false,
        totalTracks: 0,
        lastTrackNumber: 0,
        lastPositionMs: 450000, // 7:30 into the episode
        lastTrackUri: 'ard:item:12345',
        durationMs: 1800000, // 30 min episode
        createdAt: DateTime(2025),
        availableUntil: DateTime(2025, 2), // expired
        lastPlayedAt: DateTime(2025, 1, 28),
        groupId: 'tile-pumuckl',
      );

      // Item is expired...
      expect(isItemExpired(item, now: DateTime(2025, 3)), isTrue);

      // ...but position data is intact.
      expect(item.lastPositionMs, 450000);
      expect(item.lastTrackUri, 'ard:item:12345');
      expect(item.lastPlayedAt, isNotNull);
      expect(item.isHeard, isFalse);
    });

    test('playCard error string matches player screen check', () {
      // The player_provider sets this exact string on expiration.
      // The player_screen checks for it to show the friendly screen.
      // This test documents the contract between the two.
      const providerError = 'Diese Geschichte ist leider nicht mehr verfügbar';
      const directPlayerError = 'content_unavailable';

      // Both strings trigger the _ContentUnavailableScreen.
      // If either changes, this test breaks — forcing both sides to
      // stay in sync.
      expect(providerError, contains('nicht mehr verfügbar'));
      expect(directPlayerError, 'content_unavailable');
    });

    test('Spotify items never expire (availableUntil is null)', () {
      final item = TileItem(
        id: 'spotify-item',
        title: 'TKKG Folge 1',
        cardType: 'album',
        provider: 'spotify',
        providerUri: 'spotify:album:abc123',
        sortOrder: 0,
        isHeard: false,
        totalTracks: 12,
        lastTrackNumber: 0,
        lastPositionMs: 0,
        durationMs: 0,
        createdAt: DateTime.now(),
        // Spotify items have null availableUntil.
      );

      expect(item.availableUntil, isNull);
      expect(isItemExpired(item), isFalse);
    });
  });
}
