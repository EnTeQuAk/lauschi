import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/spotify/spotify_config.dart';

const _tag = 'SpotifyApi';

/// Spotify Web API client.
///
/// Handles playback control and catalog search. Token management is external —
/// call [updateToken] when the auth state changes.
class SpotifyApi {
  SpotifyApi() : _dio = Dio(BaseOptions(baseUrl: 'https://api.spotify.com/v1'));

  final Dio _dio;
  String? _accessToken;

  /// Update the access token used for API calls.
  void updateToken(String token) {
    _accessToken = token;
    _dio.options.headers['Authorization'] = 'Bearer $token';
  }

  /// Whether we have a token set.
  bool get hasToken => _accessToken != null;

  // ---------------------------------------------------------------------------
  // Playback control
  // ---------------------------------------------------------------------------

  /// Start playback of a Spotify URI on a specific device.
  ///
  /// Track URIs use `uris`, context URIs (album/playlist) use `context_uri`.
  /// Start playback of a Spotify URI.
  ///
  /// For resume: pass [offsetUri] (track URI within context) and
  /// [positionMs] to start at a specific position.
  Future<void> play(
    String spotifyUri, {
    required String deviceId,
    String? offsetUri,
    int? positionMs,
  }) async {
    final isTrack = spotifyUri.startsWith('spotify:track:');
    final body = <String, Object>{};

    if (isTrack) {
      body['uris'] = [spotifyUri];
    } else {
      body['context_uri'] = spotifyUri;
    }

    if (offsetUri != null) {
      body['offset'] = {'uri': offsetUri};
    }
    if (positionMs != null && positionMs > 0) {
      body['position_ms'] = positionMs;
    }

    Log.info(
      _tag,
      'PUT /me/player/play',
      data: {
        'uri': spotifyUri,
        'device_id': deviceId,
        if (offsetUri != null) 'offset': offsetUri,
        if (positionMs != null) 'position_ms': '$positionMs',
      },
    );

    await _request(
      () => _dio.put<void>(
        '/me/player/play',
        queryParameters: {'device_id': deviceId},
        data: json.encode(body),
      ),
    );
  }

  /// Pause playback.
  Future<void> pause() async {
    Log.debug(_tag, 'PUT /me/player/pause');
    await _request(() => _dio.put<void>('/me/player/pause'));
  }

  /// Resume playback on a specific device.
  Future<void> resume({required String deviceId}) async {
    Log.debug(_tag, 'PUT /me/player/play (resume)');
    await _request(
      () => _dio.put<void>(
        '/me/player/play',
        queryParameters: {'device_id': deviceId},
      ),
    );
  }

  /// Skip to next track.
  Future<void> nextTrack() async {
    Log.debug(_tag, 'POST /me/player/next');
    await _request(() => _dio.post<void>('/me/player/next'));
  }

  /// Skip to previous track.
  Future<void> previousTrack() async {
    Log.debug(_tag, 'POST /me/player/previous');
    await _request(() => _dio.post<void>('/me/player/previous'));
  }

  /// Seek to position in current track.
  Future<void> seek(int positionMs) async {
    Log.debug(
      _tag,
      'PUT /me/player/seek',
      data: {'position_ms': '$positionMs'},
    );
    await _request(
      () => _dio.put<void>(
        '/me/player/seek',
        queryParameters: {'position_ms': positionMs},
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Search & catalog
  // ---------------------------------------------------------------------------

  /// Search Spotify catalog for albums.
  Future<SpotifySearchResult> searchAlbums(
    String query, {
    int limit = 20,
    int offset = 0,
  }) async {
    Log.info(_tag, 'GET /search', data: {'query': query, 'limit': '$limit'});

    final resp = await _request(
      () => _dio.get<Map<String, dynamic>>(
        '/search',
        queryParameters: {
          'q': query,
          'type': 'album',
          'market': SpotifyConfig.market,
          'limit': limit,
          'offset': offset,
        },
      ),
    );

    final albums = resp?.data?['albums'] as Map<String, dynamic>? ?? {};
    final items = (albums['items'] as List<dynamic>?) ?? [];
    final total = albums['total'] as int? ?? 0;

    return SpotifySearchResult(
      albums:
          items
              .cast<Map<String, dynamic>>()
              .map(SpotifyAlbum.fromJson)
              .toList(),
      total: total,
    );
  }

  /// Get album details including track listing.
  Future<SpotifyAlbum?> getAlbum(String albumId) async {
    Log.info(_tag, 'GET /albums/$albumId');

    final resp = await _request(
      () => _dio.get<Map<String, dynamic>>(
        '/albums/$albumId',
        queryParameters: {
          'market': SpotifyConfig.market,
        },
      ),
    );

    if (resp?.data == null) return null;
    return SpotifyAlbum.fromJson(resp!.data!);
  }

  // ---------------------------------------------------------------------------
  // Request wrapper with error handling
  // ---------------------------------------------------------------------------

  Future<Response<T>?> _request<T>(
    Future<Response<T>> Function() fn,
  ) async {
    try {
      return await fn();
    } on DioException catch (e) {
      final status = e.response?.statusCode;

      if (status == 429) {
        // Rate limited — retry after delay
        final retryAfter =
            int.tryParse(e.response?.headers.value('retry-after') ?? '') ?? 1;
        Log.warn(
          _tag,
          'Rate limited, retrying',
          data: {
            'retry_after': '$retryAfter',
          },
        );
        await Future<void>.delayed(Duration(seconds: retryAfter));
        return _request(fn);
      }

      Log.error(
        _tag,
        'API error',
        data: {
          'status': '$status',
          'body': '${e.response?.data}',
        },
      );
      rethrow;
    }
  }
}

// ---------------------------------------------------------------------------
// Models
// ---------------------------------------------------------------------------

class SpotifySearchResult {
  const SpotifySearchResult({required this.albums, required this.total});

  final List<SpotifyAlbum> albums;
  final int total;
}

class SpotifyAlbum {
  const SpotifyAlbum({
    required this.id,
    required this.name,
    required this.uri,
    required this.artists,
    required this.artistIds,
    required this.imageUrl,
    required this.totalTracks,
    this.releaseDate,
    this.tracks,
  });

  factory SpotifyAlbum.fromJson(Map<String, dynamic> json) {
    final images = json['images'] as List<dynamic>? ?? [];
    final artistsRaw = json['artists'] as List<dynamic>? ?? [];
    final artistMaps = artistsRaw.cast<Map<String, dynamic>>();

    // Parse tracks if present (album detail endpoint includes them)
    List<SpotifyTrack>? tracks;
    final tracksData = json['tracks'] as Map<String, dynamic>?;
    if (tracksData != null) {
      final items = (tracksData['items'] as List<dynamic>?) ?? [];
      tracks =
          items
              .cast<Map<String, dynamic>>()
              .map(SpotifyTrack.fromJson)
              .toList();
    }

    return SpotifyAlbum(
      id: json['id'] as String,
      name: json['name'] as String,
      uri: json['uri'] as String,
      artists: artistMaps.map((a) => a['name'] as String).toList(),
      artistIds:
          artistMaps
              .map((a) => a['id'] as String? ?? '')
              .where((s) => s.isNotEmpty)
              .toList(),
      imageUrl:
          images.isNotEmpty
              ? (images.first as Map<String, dynamic>)['url'] as String?
              : null,
      totalTracks: json['total_tracks'] as int? ?? 0,
      releaseDate: json['release_date'] as String?,
      tracks: tracks,
    );
  }

  final String id;
  final String name;
  final String uri;
  final List<String> artists;

  /// Spotify artist IDs corresponding to [artists], same order.
  final List<String> artistIds;

  final String? imageUrl;
  final int totalTracks;
  final String? releaseDate;
  final List<SpotifyTrack>? tracks;

  String get artistNames => artists.join(', ');
}

class SpotifyTrack {
  const SpotifyTrack({
    required this.id,
    required this.name,
    required this.uri,
    required this.trackNumber,
    required this.durationMs,
  });

  factory SpotifyTrack.fromJson(Map<String, dynamic> json) {
    return SpotifyTrack(
      id: json['id'] as String,
      name: json['name'] as String,
      uri: json['uri'] as String,
      trackNumber: json['track_number'] as int? ?? 0,
      durationMs: json['duration_ms'] as int? ?? 0,
    );
  }

  final String id;
  final String name;
  final String uri;
  final int trackNumber;
  final int durationMs;
}
