import 'dart:async';

import 'package:fake_async/fake_async.dart';
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

    test('throws instead of returning a truncated list on a persistent '
        'mid-pagination failure', () async {
      final adapter = FakeHttpAdapter((options) {
        final offset = options.queryParameters['offset']! as int;
        if (offset == 0) {
          return {
            'data': [for (var n = 1; n <= 100; n++) _track(n)],
            'next': '/v1/catalog/de/albums/album-1/tracks?offset=100',
          };
        }
        throw Exception('network down'); // page 2 always fails
      });

      await expectLater(
        _apiWith(adapter).getAlbumTracks('album-1'),
        throwsA(isA<Exception>()),
        reason: 'a failed page must not become a silently short track list',
      );
    });

    test(
      'retries a transient page failure and returns the full list',
      () async {
        var page2Calls = 0;
        final adapter = FakeHttpAdapter((options) {
          final offset = options.queryParameters['offset']! as int;
          if (offset == 0) {
            return {
              'data': [for (var n = 1; n <= 100; n++) _track(n)],
              'next': '/v1/catalog/de/albums/album-1/tracks?offset=100',
            };
          }
          page2Calls++;
          if (page2Calls == 1) throw Exception('transient blip');
          return {
            'data': [for (var n = 101; n <= 150; n++) _track(n)],
          };
        });

        final tracks = await _apiWith(adapter).getAlbumTracks('album-1');

        expect(tracks, hasLength(150));
        expect(
          page2Calls,
          2,
          reason: 'page 2 failed once, then succeeded on retry',
        );
      },
    );

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

  group('AppleMusicApi.getAlbumCover coalescing', () {
    test('flushes while cards keep mounting, not only after scroll stops', () {
      fakeAsync((async) {
        final adapter = FakeHttpAdapter((_) => {'data': <dynamic>[]});
        final api = _apiWith(adapter);

        // A fling: cards mount every 40ms, shorter than the 50ms batch
        // window. A debounce that cancels+reschedules on every call never
        // reaches 50ms and fires nothing until the fling stops. A throttle
        // fires ~50ms after the first pending id regardless.
        for (var i = 0; i < 10; i++) {
          unawaited(api.getAlbumCover('album-$i'));
          async.elapse(const Duration(milliseconds: 40));
        }

        expect(
          adapter.requests,
          isNotEmpty,
          reason: 'covers must load while scrolling, not stall until it pauses',
        );

        async.elapse(const Duration(milliseconds: 100));
      });
    });

    test('resolves each coalesced id at its own requested size', () {
      fakeAsync((async) {
        final adapter = FakeHttpAdapter(
          (_) => {
            'data': [
              for (final id in ['a', 'b'])
                {
                  'id': id,
                  'attributes': {
                    'name': id,
                    'artwork': {'url': 'https://img/$id/{w}x{h}.jpg'},
                  },
                },
            ],
          },
        );
        final api = _apiWith(adapter);

        // Two ids coalesced into one batch but requesting different sizes.
        // Each must resolve its own template, not share the last (or
        // first) caller's size.
        final results = <String, String?>{};
        for (final (id, size) in [('a', 200), ('b', 600)]) {
          unawaited(
            api.getAlbumCover(id, size: size).then((u) => results[id] = u),
          );
        }

        async
          ..elapse(const Duration(milliseconds: 100))
          ..flushMicrotasks();

        expect(results['a'], 'https://img/a/200x200.jpg');
        expect(results['b'], 'https://img/b/600x600.jpg');
      });
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
