import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/database/app_database.dart';
import 'package:lauschi/core/database/tile_item_repository.dart';
import 'package:lauschi/features/player/player_error.dart';

/// Test that position data survives expiration and that the expiration
/// semantics are correct (only markedUnavailable, not availableUntil).
void main() {
  group('expiration preserves playback state', () {
    test('unavailable item retains position data', () {
      // Simulate an item that was being listened to, then marked unavailable.
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
        markedUnavailable: DateTime(2025, 2),
        lastPlayedAt: DateTime(2025, 1, 28),
        groupId: 'tile-pumuckl',
      );

      expect(isItemExpired(item), isTrue);

      // Position data is intact for when content comes back.
      expect(item.lastPositionMs, 450000);
      expect(item.lastTrackUri, 'ard:item:12345');
      expect(item.lastPlayedAt, isNotNull);
      expect(item.isHeard, isFalse);
    });

    test('availableUntil in the past does NOT make item expired', () {
      // ARD's endDate is an editorial broadcast window, not content removal.
      // Audio URLs remain on CDN well past endDate.
      final item = TileItem(
        id: 'item-2',
        title: 'Gute Nacht mit der Maus',
        cardType: 'episode',
        provider: 'ard_audiothek',
        providerUri: 'ard:item:67890',
        sortOrder: 0,
        isHeard: false,
        totalTracks: 0,
        lastTrackNumber: 0,
        lastPositionMs: 0,
        durationMs: 1320000,
        createdAt: DateTime(2025),
        availableUntil: DateTime(2025, 2), // past, but audio still works
      );

      expect(isItemExpired(item), isFalse);
    });

    test(
      'contentUnavailable has the "gone" error category',
      () {
        expect(
          PlayerError.contentUnavailable.category,
          ErrorCategory.gone,
        );

        // Retryable errors use the "oops" category.
        for (final error in [
          PlayerError.playbackFailed,
          PlayerError.spotifyConnectionLost,
          PlayerError.spotifyNetworkError,
        ]) {
          expect(
            error.category,
            ErrorCategory.oops,
            reason: '$error should be oops category',
          );
        }

        // Auth errors need parent action.
        expect(
          PlayerError.spotifyAuthExpired.category,
          ErrorCategory.parentAction,
        );
      },
    );

    test('Spotify items without markedUnavailable are not expired', () {
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
      );

      expect(item.availableUntil, isNull);
      expect(item.markedUnavailable, isNull);
      expect(isItemExpired(item), isFalse);
    });
  });
}
