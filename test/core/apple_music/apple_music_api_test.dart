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

    test('skips a malformed track instead of crashing playback', () async {
      // A track item missing its id makes `item['id'] as String` throw a
      // TypeError — an Error, not an Exception — that escapes the
      // `on DioException` catch and propagates into play()'s queue build,
      // killing playback for the whole album. One bad item must be skipped.
      final adapter = FakeHttpAdapter(
        (_) => {
          'data': [
            _track(1),
            {
              // no 'id'
              'attributes': {'name': 'Ghost', 'trackNumber': 2},
            },
            _track(3),
          ],
        },
      );

      final tracks = await _apiWith(adapter).getAlbumTracks('album-1');

      expect(tracks.map((t) => t.id), ['track-1', 'track-3']);
    });
  });

  group('AppleMusicApi.getAlbumCover', () {
    test('resolves (not hangs) when Apple returns a different id', () async {
      // Apple can canonicalize a requested album id to an equivalent one,
      // so the returned album's id isn't a key in the pending batch. A
      // bare `batch[id]!` then throws a null-check Error that escapes the
      // `on Exception` handler and leaves every pending cover completer
      // hung on a spinner. The requested id must resolve (to null), not
      // hang.
      final adapter = FakeHttpAdapter(
        (_) => {
          'data': [
            {
              'id': 'canonical-id',
              'attributes': {
                'name': 'Album',
                'artwork': {'url': 'https://img/{w}x{h}.jpg'},
              },
            },
          ],
        },
      );

      final url = await _apiWith(adapter)
          .getAlbumCover('requested-id')
          .timeout(
            const Duration(seconds: 2),
            onTimeout: () => 'TIMEOUT',
          );

      expect(url, isNull);
    });
  });

  group('AppleMusicApi.searchAlbums', () {
    test('skips a malformed album instead of failing the search', () async {
      final adapter = FakeHttpAdapter(
        (_) => {
          'results': {
            'albums': {
              'data': [
                {
                  'id': 'album-1',
                  'attributes': {'name': 'Bibi Blocksberg', 'trackCount': 12},
                },
                {
                  // no 'id'
                  'attributes': {'name': 'Ghost album'},
                },
              ],
            },
          },
        },
      );

      final albums = await _apiWith(adapter).searchAlbums('bibi');

      expect(albums.map((a) => a.id), ['album-1']);
    });
  });
}
