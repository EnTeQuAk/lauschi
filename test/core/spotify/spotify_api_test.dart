import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/spotify/spotify_api.dart';

/// Serves canned JSON per request, recording what was asked for.
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);

  final Map<String, dynamic> Function(RequestOptions options) handler;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode(handler(options)),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

SpotifyApi _apiWith(_FakeAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'https://api.spotify.com/v1'))
    ..httpClientAdapter = adapter;
  return SpotifyApi.withDio(dio)..updateToken('test-token');
}

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
      final adapter = _FakeAdapter((options) {
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
      final adapter = _FakeAdapter(
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

  group('SpotifyAlbum.imageUrlForSize', () {
    const album = SpotifyAlbum(
      id: 'a',
      name: 'A',
      uri: 'spotify:album:a',
      artists: ['X'],
      artistIds: ['x'],
      imageUrl: 'https://img/640',
      totalTracks: 1,
      images: [
        (url: 'https://img/640', width: 640),
        (url: 'https://img/300', width: 300),
        (url: 'https://img/64', width: 64),
      ],
    );

    test('picks the smallest rendition covering the requested size', () {
      expect(album.imageUrlForSize(300), 'https://img/300');
      expect(album.imageUrlForSize(200), 'https://img/300');
      expect(album.imageUrlForSize(64), 'https://img/64');
      expect(album.imageUrlForSize(400), 'https://img/640');
    });

    test('falls back to the largest when nothing is big enough', () {
      expect(album.imageUrlForSize(2000), 'https://img/640');
    });

    test('falls back to imageUrl when no sized renditions exist', () {
      const bare = SpotifyAlbum(
        id: 'a',
        name: 'A',
        uri: 'spotify:album:a',
        artists: ['X'],
        artistIds: ['x'],
        imageUrl: 'https://img/only',
        totalTracks: 1,
      );
      expect(bare.imageUrlForSize(300), 'https://img/only');
    });
  });
}
