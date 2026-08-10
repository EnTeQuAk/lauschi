import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/spotify/spotify_api.dart';

import '../../helpers/fake_http_adapter.dart';

SpotifyApi _apiWith(FakeHttpAdapter adapter) =>
    SpotifyApi(adapter: adapter)..updateToken('test-token');

Map<String, dynamic> _track(int n) => {
  'id': 'track-$n',
  'name': 'Track $n',
  'uri': 'spotify:track:track-$n',
  'track_number': n,
  'duration_ms': 60000,
  'artists': [
    {'id': 'artist-1', 'name': 'Artist'},
  ],
};

void main() {
  group('SpotifyApi.getAlbumTracks', () {
    test('follows pagination past 50 tracks', () async {
      // A 70-track Kinderlieder compilation: two pages of 50 + 20.
      final adapter = FakeHttpAdapter((options) {
        expect(options.path, '/albums/album-1/tracks');
        final offset = options.queryParameters['offset']! as int;
        final isLast = offset >= 50;
        return {
          'items': [
            for (var n = offset + 1; n <= (isLast ? 70 : 50); n++) _track(n),
          ],
          'next': isLast ? null : 'https://api.spotify.com/v1/next-page',
        };
      });

      final tracks = await _apiWith(adapter).getAlbumTracks('album-1');

      expect(tracks, hasLength(70));
      expect(tracks.first.name, 'Track 1');
      expect(tracks.last.name, 'Track 70');
      expect(
        adapter.requests.map((r) => r.queryParameters['offset']),
        [0, 50],
        reason: 'exactly one follow-up page request',
      );
    });

    test('single page needs one request', () async {
      final adapter = FakeHttpAdapter(
        (_) => {
          'items': [_track(1), _track(2)],
          'next': null,
        },
      );

      final tracks = await _apiWith(adapter).getAlbumTracks('album-1');

      expect(tracks, hasLength(2));
      expect(adapter.requests, hasLength(1));
    });
  });

  group('SpotifyAlbum artwork', () {
    test('imageUrl is the largest rendition', () {
      const album = SpotifyAlbum(
        id: 'a',
        name: 'A',
        uri: 'spotify:album:a',
        artists: ['X'],
        artistIds: ['x'],
        totalTracks: 1,
        images: [
          (url: 'https://img/640', width: 640),
          (url: 'https://img/300', width: 300),
        ],
      );
      expect(album.imageUrl, 'https://img/640');
    });

    test('imageUrl is null without renditions', () {
      const album = SpotifyAlbum(
        id: 'a',
        name: 'A',
        uri: 'spotify:album:a',
        artists: ['X'],
        artistIds: ['x'],
        totalTracks: 1,
      );
      expect(album.imageUrl, isNull);
    });
  });
}
