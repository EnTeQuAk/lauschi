import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/spotify/spotify_config.dart';

const _tag = 'SpotifyApi';

/// Thrown when Spotify returns a device error (typically 404 or 400 with
/// "Device not found") — the SDK player device_id is stale and needs
/// re-registration.
class SpotifyDeviceNotFoundException implements Exception {
  const SpotifyDeviceNotFoundException(this.message);
  final String message;
  @override
  String toString() => 'SpotifyDeviceNotFoundException: $message';
}

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
              .whereType<Map<String, dynamic>>()
              .map(SpotifyAlbum.fromJson)
              .toList(),
      total: total,
    );
  }

  /// Search Spotify catalog for playlists.
  Future<SpotifyPlaylistSearchResult> searchPlaylists(
    String query, {
    int limit = 20,
    int offset = 0,
  }) async {
    Log.info(
      _tag,
      'GET /search (playlists)',
      data: {'query': query, 'limit': '$limit'},
    );

    final resp = await _request(
      () => _dio.get<Map<String, dynamic>>(
        '/search',
        queryParameters: {
          'q': query,
          'type': 'playlist',
          'market': SpotifyConfig.market,
          'limit': limit,
          'offset': offset,
        },
      ),
    );

    final playlists = resp?.data?['playlists'] as Map<String, dynamic>? ?? {};
    final items = (playlists['items'] as List<dynamic>?) ?? [];
    final total = playlists['total'] as int? ?? 0;

    return SpotifyPlaylistSearchResult(
      playlists:
          items
              .whereType<Map<String, dynamic>>()
              .map(SpotifyPlaylist.fromJson)
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

  /// Get multiple albums in one request (max 20 IDs per Spotify API limit).
  ///
  /// Returns albums in the same order as [albumIds]. Missing/unavailable
  /// albums are omitted (result may be shorter than input).
  Future<List<SpotifyAlbum>> getAlbums(List<String> albumIds) async {
    if (albumIds.isEmpty) return [];
    assert(albumIds.length <= 20, 'Spotify allows max 20 IDs per request');

    Log.info(
      _tag,
      'GET /albums?ids=...',
      data: {'count': '${albumIds.length}'},
    );

    final resp = await _request(
      () => _dio.get<Map<String, dynamic>>(
        '/albums',
        queryParameters: {
          'ids': albumIds.join(','),
          'market': SpotifyConfig.market,
        },
      ),
    );

    final items = (resp?.data?['albums'] as List<dynamic>?) ?? [];
    return items
        .whereType<Map<String, dynamic>>()
        .map(SpotifyAlbum.fromJson)
        .toList();
  }

  /// Get playlist details including first page of tracks.
  Future<SpotifyPlaylistDetail?> getPlaylist(String playlistId) async {
    Log.info(_tag, 'GET /playlists/$playlistId');

    final resp = await _request(
      () => _dio.get<Map<String, dynamic>>(
        '/playlists/$playlistId',
        queryParameters: {
          'market': SpotifyConfig.market,
          'fields':
              'id,name,uri,description,images,'
              'owner(display_name),'
              'tracks.items(track(id,name,uri,track_number,duration_ms,artists(name))),'
              'tracks.total',
        },
      ),
    );

    if (resp?.data == null) return null;
    return SpotifyPlaylistDetail.fromJson(resp!.data!);
  }

  /// Get artist image URL. Returns the first (largest) image, or null.
  Future<String?> getArtistImage(String artistId) async {
    Log.info(_tag, 'GET /artists/$artistId (image)');

    final resp = await _request(
      () => _dio.get<Map<String, dynamic>>(
        '/artists/$artistId',
        queryParameters: {'fields': 'images'},
      ),
    );

    if (resp?.data == null) return null;
    final images = resp!.data!['images'] as List<dynamic>?;
    if (images == null || images.isEmpty) return null;
    return (images.first as Map<String, dynamic>)['url'] as String?;
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

      // Connection errors (no internet, DNS failure) are transient —
      // don't spam Sentry.
      if (e.type == DioExceptionType.connectionError ||
          e.type == DioExceptionType.connectionTimeout) {
        Log.warn(_tag, 'Network unavailable');
        return null;
      }

      Log.error(
        _tag,
        'API error',
        data: {
          'status': '$status',
          'body': '${e.response?.data}',
        },
      );

      // Stale device_id — Spotify returns 404 or sometimes 400 with
      // "Device not found" in the error body.
      final body = e.response?.data;
      final message =
          body is Map ? '${(body['error'] as Map?)?['message']}' : '$body';

      if (status == 404 ||
          (status == 400 &&
              message.toLowerCase().contains('device not found'))) {
        throw SpotifyDeviceNotFoundException(message);
      }

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
    this.albumType,
    this.releaseDate,
    this.tracks,
  });

  factory SpotifyAlbum.fromJson(Map<String, dynamic> json) {
    final images = json['images'] as List<dynamic>? ?? [];
    final artistsRaw = json['artists'] as List<dynamic>? ?? [];
    final artistMaps = artistsRaw.whereType<Map<String, dynamic>>();

    // Parse tracks if present (album detail endpoint includes them)
    List<SpotifyTrack>? tracks;
    final tracksData = json['tracks'] as Map<String, dynamic>?;
    if (tracksData != null) {
      final items = (tracksData['items'] as List<dynamic>?) ?? [];
      tracks =
          items
              .whereType<Map<String, dynamic>>()
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
      albumType: json['album_type'] as String?,
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

  /// 'album', 'single', or 'compilation'.
  final String? albumType;
  final String? releaseDate;
  final List<SpotifyTrack>? tracks;

  String get artistNames => artists.join(', ');
}

class SpotifyPlaylistSearchResult {
  const SpotifyPlaylistSearchResult({
    required this.playlists,
    required this.total,
  });

  final List<SpotifyPlaylist> playlists;
  final int total;
}

class SpotifyPlaylist {
  const SpotifyPlaylist({
    required this.id,
    required this.name,
    required this.uri,
    required this.ownerName,
    required this.imageUrl,
    required this.totalTracks,
  });

  factory SpotifyPlaylist.fromJson(Map<String, dynamic> json) {
    final images = json['images'] as List<dynamic>? ?? [];
    final owner = json['owner'] as Map<String, dynamic>? ?? {};

    return SpotifyPlaylist(
      id: json['id'] as String,
      name: json['name'] as String,
      uri: json['uri'] as String,
      ownerName: owner['display_name'] as String? ?? '',
      imageUrl:
          images.isNotEmpty
              ? (images.first as Map<String, dynamic>)['url'] as String?
              : null,
      totalTracks:
          (json['tracks'] as Map<String, dynamic>?)?['total'] as int? ?? 0,
    );
  }

  final String id;
  final String name;
  final String uri;
  final String ownerName;
  final String? imageUrl;
  final int totalTracks;
}

class SpotifyTrack {
  const SpotifyTrack({
    required this.id,
    required this.name,
    required this.uri,
    required this.trackNumber,
    required this.durationMs,
    this.artistNames,
  });

  factory SpotifyTrack.fromJson(Map<String, dynamic> json) {
    final artistsRaw = json['artists'] as List<dynamic>?;
    final artistNames = artistsRaw
        ?.whereType<Map<String, dynamic>>()
        .map((a) => a['name'] as String)
        .join(', ');

    return SpotifyTrack(
      id: json['id'] as String,
      name: json['name'] as String,
      uri: json['uri'] as String,
      trackNumber: json['track_number'] as int? ?? 0,
      durationMs: json['duration_ms'] as int? ?? 0,
      artistNames: artistNames,
    );
  }

  final String id;
  final String name;
  final String uri;
  final int trackNumber;
  final int durationMs;
  final String? artistNames;
}

/// Full playlist detail with tracks (from GET /playlists/{id}).
class SpotifyPlaylistDetail {
  const SpotifyPlaylistDetail({
    required this.id,
    required this.name,
    required this.uri,
    required this.ownerName,
    required this.imageUrl,
    required this.totalTracks,
    required this.tracks,
  });

  factory SpotifyPlaylistDetail.fromJson(Map<String, dynamic> json) {
    final images = json['images'] as List<dynamic>? ?? [];
    final owner = json['owner'] as Map<String, dynamic>? ?? {};
    final tracksData = json['tracks'] as Map<String, dynamic>? ?? {};
    final items = (tracksData['items'] as List<dynamic>?) ?? [];

    final tracks = <SpotifyTrack>[];
    for (final item in items.whereType<Map<String, dynamic>>()) {
      final track = item['track'] as Map<String, dynamic>?;
      if (track != null && track['id'] != null) {
        tracks.add(SpotifyTrack.fromJson(track));
      }
    }

    return SpotifyPlaylistDetail(
      id: json['id'] as String,
      name: json['name'] as String,
      uri: json['uri'] as String,
      ownerName: owner['display_name'] as String? ?? '',
      imageUrl:
          images.isNotEmpty
              ? (images.first as Map<String, dynamic>)['url'] as String?
              : null,
      totalTracks: (tracksData['total'] as int?) ?? tracks.length,
      tracks: tracks,
    );
  }

  final String id;
  final String name;
  final String uri;
  final String ownerName;
  final String? imageUrl;
  final int totalTracks;
  final List<SpotifyTrack> tracks;
}
