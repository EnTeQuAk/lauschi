import 'dart:async' show Completer, Timer, unawaited;
import 'dart:io' show Platform;

import 'package:dio/dio.dart';
import 'package:lauschi/core/apple_music/apple_music_config.dart';
import 'package:lauschi/core/log.dart';
import 'package:music_kit/music_kit.dart';

const _tag = 'AppleMusicApi';

/// Album from the Apple Music catalog.
class AppleMusicAlbum {
  const AppleMusicAlbum({
    required this.id,
    required this.name,
    required this.artistName,
    this.artworkUrl,
    this.trackCount = 0,
    this.releaseDate,
    this.genreNames = const [],
  });

  final String id;
  final String name;
  final String artistName;
  final String? artworkUrl;
  final int trackCount;
  final String? releaseDate;
  final List<String> genreNames;

  /// Provider URI for storage in the tile item table.
  String get providerUri => 'apple_music:album:$id';

  /// Resolve artwork URL template to a specific size.
  /// Apple returns URLs like `{w}x{h}bb.jpg`.
  String? artworkUrlForSize(int size) {
    if (artworkUrl == null) return null;
    return artworkUrl!.replaceAll('{w}', '$size').replaceAll('{h}', '$size');
  }
}

/// Track from an Apple Music album.
class AppleMusicTrack {
  const AppleMusicTrack({
    required this.id,
    required this.name,
    required this.trackNumber,
    required this.durationMs,
    this.artistName,
    this.artworkUrl,
  });

  final String id;
  final String name;
  final int trackNumber;
  final int durationMs;
  final String? artistName;
  final String? artworkUrl;
}

/// Client for the Apple Music API (catalog search + metadata).
///
/// Uses the REST API directly (not MusicKit playback). The MusicKit
/// plugin handles auth tokens; we use them for API calls.
class AppleMusicApi {
  AppleMusicApi(this._musicKit)
    : _dio = Dio(
        BaseOptions(
          baseUrl: 'https://api.music.apple.com/v1',
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 15),
        ),
      );

  final MusicKit _musicKit;
  final Dio _dio;
  String? _developerToken;
  String? _userToken;
  String? _storefront;
  bool _initialized = false;

  // ── Cover request coalescing ──────────────────────────────────────
  // When multiple cards request covers simultaneously (per-card loading),
  // we collect IDs for a short window then fire one batched API call.
  final _pendingCoverIds = <String, Completer<String?>>{};
  Timer? _coverBatchTimer;

  /// Whether init() completed successfully.
  bool get isInitialized => _initialized;

  /// Get a single album's cover URL with request coalescing.
  ///
  /// Collects IDs for 50ms, then fires one batched API call for all
  /// pending IDs. Returns null if the album has no artwork or the
  /// request fails.
  ///
  /// Call [cancelCover] to remove an ID from the pending batch before
  /// the timer fires (e.g. when the card scrolls off screen).
  Future<String?> getAlbumCover(String albumId, {int size = 300}) {
    final existing = _pendingCoverIds[albumId];
    if (existing != null) return existing.future;

    final completer = Completer<String?>();
    _pendingCoverIds[albumId] = completer;

    _coverBatchTimer?.cancel();
    _coverBatchTimer = Timer(const Duration(milliseconds: 50), () {
      unawaited(_flushCoverBatch(size));
    });

    return completer.future;
  }

  /// Remove an album from the pending cover batch.
  ///
  /// If the batch hasn't fired yet, the ID is removed so it won't be
  /// included in the API call. If it's already in flight, this is a no-op
  /// (the result is just ignored by the disposed provider).
  void cancelCover(String albumId) {
    final completer = _pendingCoverIds.remove(albumId);
    if (completer != null && !completer.isCompleted) {
      completer.complete(null);
    }
  }

  Future<void> _flushCoverBatch(int size) async {
    final batch = Map<String, Completer<String?>>.of(_pendingCoverIds);
    _pendingCoverIds.clear();
    if (batch.isEmpty) return;

    // Remove already-completed entries (cancelled while waiting for timer)
    batch.removeWhere((_, c) => c.isCompleted);
    if (batch.isEmpty) return;

    Log.info(
      _tag,
      'Cover batch flush',
      data: {'count': '${batch.length}'},
    );

    try {
      final albums = await getAlbums(batch.keys.toList());
      final resolved = <String>{};
      for (final album in albums) {
        final url = album.artworkUrlForSize(size);
        if (!batch[album.id]!.isCompleted) {
          batch[album.id]!.complete(url);
        }
        resolved.add(album.id);
      }
      // Complete any unresolved (album not found / removed)
      for (final entry in batch.entries) {
        if (!resolved.contains(entry.key) && !entry.value.isCompleted) {
          entry.value.complete(null);
        }
      }
    } on Exception catch (e) {
      for (final completer in batch.values) {
        if (!completer.isCompleted) completer.complete(null);
      }
      Log.warn(_tag, 'Cover batch failed', data: {'error': '$e'});
    }
  }

  /// Initialize with a known user token and storefront.
  ///
  /// Called by the session after auth completes, passing the token it
  /// already has. No network calls, can't fail.
  void initWith({required String userToken, String storefront = 'de'}) {
    if (_initialized) return;

    if (Platform.isIOS) {
      // iOS: token from MusicKit capability, no dart-define needed.
      // Deferred until we actually build for iOS.
      _developerToken = '';
    } else {
      _developerToken = AppleMusicConfig.developerToken;
    }

    _userToken = userToken;
    _storefront = storefront;
    _dio.options.headers['Authorization'] = 'Bearer $_developerToken';
    _dio.options.headers['Music-User-Token'] = _userToken;
    _initialized = true;

    Log.info(
      _tag,
      'Initialized',
      data: {'storefront': _storefront!},
    );
  }

  /// Legacy init that fetches tokens from MusicKit SDK.
  /// Only used as fallback if initWith() wasn't called.
  Future<void> init() async {
    if (_initialized) return;
    try {
      if (Platform.isIOS) {
        _developerToken = await _musicKit.requestDeveloperToken();
      } else {
        _developerToken = AppleMusicConfig.developerToken;
      }
      _userToken = await _musicKit.requestUserToken(
        _developerToken!,
      );
      // Default to 'de' instead of fetching from Apple's API.
      // The storefront call times out frequently on Android.
      _storefront = 'de';

      _dio.options.headers['Authorization'] = 'Bearer $_developerToken';
      if (_userToken != null && _userToken!.isNotEmpty) {
        _dio.options.headers['Music-User-Token'] = _userToken;
      }

      _initialized = true;
      Log.info(
        _tag,
        'Initialized (fallback)',
        data: {'storefront': _storefront!},
      );
    } on Exception catch (e) {
      Log.error(_tag, 'Init failed', exception: e);
      rethrow;
    }
  }

  /// Search the Apple Music catalog for albums matching [query].
  ///
  /// Filters to the user's storefront (e.g. "de" for Germany).
  /// Returns albums only (not songs, playlists, etc.).
  Future<List<AppleMusicAlbum>> searchAlbums(
    String query, {
    int limit = 25,
  }) async {
    if (!_initialized) await init();

    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/catalog/${_storefront!}/search',
        queryParameters: {
          'term': query,
          'types': 'albums',
          'limit': limit,
        },
      );

      final results = response.data?['results'] as Map<String, dynamic>?;
      final albumsData = results?['albums'] as Map<String, dynamic>?;
      final data = albumsData?['data'] as List<dynamic>? ?? [];

      return data.map<AppleMusicAlbum>((e) {
        final item = e as Map<String, dynamic>;
        final attrs =
            item['attributes'] as Map<String, dynamic>? ?? <String, dynamic>{};
        final artwork = attrs['artwork'] as Map<String, dynamic>?;
        return AppleMusicAlbum(
          id: item['id'] as String,
          name: attrs['name'] as String,
          artistName: attrs['artistName'] as String? ?? '',
          artworkUrl: artwork?['url'] as String?,
          trackCount: attrs['trackCount'] as int? ?? 0,
          releaseDate: attrs['releaseDate'] as String?,
          genreNames:
              (attrs['genreNames'] as List<dynamic>?)?.cast<String>() ?? [],
        );
      }).toList();
    } on DioException catch (e) {
      Log.error(
        _tag,
        'Search failed',
        data: {'query': query, 'status': '${e.response?.statusCode}'},
      );
      return [];
    }
  }

  /// Batch-fetch multiple albums by ID.
  ///
  /// Apple Music supports up to 25 IDs per request via the `ids` parameter.
  Future<List<AppleMusicAlbum>> getAlbums(List<String> albumIds) async {
    if (albumIds.isEmpty) return [];
    if (!_initialized) {
      try {
        await init();
      } on Exception {
        return [];
      }
    }

    Log.info(
      _tag,
      'getAlbums batch',
      data: {
        'count': '${albumIds.length}',
        'storefront': _storefront ?? 'null',
        'sampleIds': albumIds.take(3).join(','),
      },
    );

    final results = <AppleMusicAlbum>[];
    // Apple Music allows max 25 IDs per batch request.
    for (var i = 0; i < albumIds.length; i += 25) {
      final batch = albumIds.sublist(
        i,
        (i + 25).clamp(0, albumIds.length),
      );
      try {
        final response = await _dio.get<Map<String, dynamic>>(
          '/catalog/${_storefront!}/albums',
          queryParameters: {'ids': batch.join(',')},
        );
        final data = response.data?['data'] as List<dynamic>? ?? [];
        for (final e in data) {
          final item = e as Map<String, dynamic>;
          final attrs =
              item['attributes'] as Map<String, dynamic>? ??
              <String, dynamic>{};
          final artwork = attrs['artwork'] as Map<String, dynamic>?;
          results.add(
            AppleMusicAlbum(
              id: item['id'] as String,
              name: attrs['name'] as String? ?? '',
              artistName: attrs['artistName'] as String? ?? '',
              artworkUrl: artwork?['url'] as String?,
              trackCount: attrs['trackCount'] as int? ?? 0,
              releaseDate: attrs['releaseDate'] as String?,
              genreNames:
                  (attrs['genreNames'] as List<dynamic>?)?.cast<String>() ?? [],
            ),
          );
        }
        Log.debug(
          _tag,
          'Batch album fetch OK',
          data: {
            'requested': '${batch.length}',
            'returned': '${data.length}',
            'sampleArtwork':
                results.isNotEmpty
                    ? '${results.last.artworkUrl?.substring(0, 60) ?? "null"}...'
                    : 'none',
          },
        );
      } on DioException catch (e) {
        Log.error(
          _tag,
          'Batch album fetch failed',
          data: {
            'count': '${batch.length}',
            'status': '${e.response?.statusCode}',
            'error': '${e.message}',
            'url': '${e.requestOptions.uri}',
          },
        );
      }
    }
    Log.info(_tag, 'getAlbums done', data: {'total': '${results.length}'});
    return results;
  }

  /// Get a single album by ID.
  Future<AppleMusicAlbum?> getAlbum(String albumId) async {
    if (!_initialized) await init();

    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/catalog/${_storefront!}/albums/$albumId',
      );

      final data = response.data?['data'] as List<dynamic>?;
      if (data == null || data.isEmpty) return null;

      final item = data[0] as Map<String, dynamic>;
      final attrs =
          item['attributes'] as Map<String, dynamic>? ?? <String, dynamic>{};
      final artwork = attrs['artwork'] as Map<String, dynamic>?;
      return AppleMusicAlbum(
        id: item['id'] as String,
        name: attrs['name'] as String,
        artistName: attrs['artistName'] as String? ?? '',
        artworkUrl: artwork?['url'] as String?,
        trackCount: attrs['trackCount'] as int? ?? 0,
        releaseDate: attrs['releaseDate'] as String?,
        genreNames:
            (attrs['genreNames'] as List<dynamic>?)?.cast<String>() ?? [],
      );
    } on DioException catch (e) {
      Log.error(
        _tag,
        'Get album failed',
        data: {'albumId': albumId, 'status': '${e.response?.statusCode}'},
      );
      return null;
    }
  }

  /// Get tracks for an album.
  Future<List<AppleMusicTrack>> getAlbumTracks(String albumId) async {
    if (!_initialized) await init();

    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/catalog/${_storefront!}/albums/$albumId',
        queryParameters: {
          'include': 'tracks',
        },
      );

      final data = response.data?['data'] as List<dynamic>?;
      if (data == null || data.isEmpty) return [];

      final firstItem = data[0] as Map<String, dynamic>;
      final relationships = firstItem['relationships'] as Map<String, dynamic>?;
      final tracksMap = relationships?['tracks'] as Map<String, dynamic>?;
      final tracksData = tracksMap?['data'] as List<dynamic>? ?? [];

      return tracksData.map<AppleMusicTrack>((e) {
        final item = e as Map<String, dynamic>;
        final attrs =
            item['attributes'] as Map<String, dynamic>? ?? <String, dynamic>{};
        final artwork = attrs['artwork'] as Map<String, dynamic>?;
        return AppleMusicTrack(
          id: item['id'] as String,
          name: attrs['name'] as String,
          trackNumber: attrs['trackNumber'] as int? ?? 0,
          durationMs: attrs['durationInMillis'] as int? ?? 0,
          artistName: attrs['artistName'] as String?,
          artworkUrl: artwork?['url'] as String?,
        );
      }).toList();
    } on DioException catch (e) {
      Log.error(
        _tag,
        'Get album tracks failed',
        data: {'albumId': albumId, 'status': '${e.response?.statusCode}'},
      );
      return [];
    }
  }
}
