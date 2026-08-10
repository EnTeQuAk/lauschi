import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/apple_music/apple_music_api.dart';

import '../../helpers/fake_http_adapter.dart';

AppleMusicApi _apiWith(FakeHttpAdapter adapter) =>
    AppleMusicApi(adapter: adapter)
      ..configure(developerToken: 'test-jwt', storefront: 'de');

Map<String, dynamic> _track(int n) => {
  'id': 'track-$n',
  'attributes': {
    'name': 'Track $n',
    'trackNumber': n,
    'durationInMillis': 60000,
    'artistName': 'Artist',
  },
};

void main() {
  group('AppleMusicApi.getAlbumTracks', () {
    test('follows pagination past the first page', () async {
      // A 150-track compilation: pages of 100 + 50.
      final adapter = FakeHttpAdapter((options) {
        expect(options.path, '/albums/album-1/tracks');
        final offset = options.queryParameters['offset']! as int;
        final isLast = offset >= 100;
        return {
          'data': [
            for (var n = offset + 1; n <= (isLast ? 150 : 100); n++) _track(n),
          ],
          if (!isLast)
            'next': '/v1/catalog/de/albums/album-1/tracks?offset=100',
        };
      });

      final tracks = await _apiWith(adapter).getAlbumTracks('album-1');

      expect(tracks, hasLength(150));
      expect(tracks.first.name, 'Track 1');
      expect(tracks.last.name, 'Track 150');
      expect(
        adapter.requests.map((r) => r.queryParameters['offset']),
        [0, 100],
        reason: 'exactly one follow-up page request',
      );
    });

    test('single page needs one request', () async {
      final adapter = FakeHttpAdapter(
        (_) => {
          'data': [_track(1), _track(2)],
        },
      );

      final tracks = await _apiWith(adapter).getAlbumTracks('album-1');

      expect(tracks, hasLength(2));
      expect(tracks.first.trackNumber, 1);
      expect(adapter.requests, hasLength(1));
    });
  });
}
