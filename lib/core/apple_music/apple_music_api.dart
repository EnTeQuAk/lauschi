import 'dart:async' show Completer, Timer, unawaited;

import 'package:dio/dio.dart';
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
  });

  final String id;
  final String name;
  final int trackNumber;
  final int durationMs;
  final String? artistName;
}

/// REST API client for Apple Music catalog operations.
///
/// Uses the developer token (generated on-device by the MusicKit plugin)
/// and the user token (obtained during auth) for API requests.
/// Storefront defaults to the user's region (resolved by the plugin)
/// or 'de' as fallback.
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
  bool _initialized = false;

  bool get isInitialized => _initialized;

  /// Set up auth headers from the MusicKit plugin.
  ///
  /// Called by the session after auth completes. Gets the developer token
  /// (generated on-device from .p8 key) and user token from the plugin.
  /// Storefront resolved by plugin, defaults to 'de'.
  void init() {
    // Tokens are fetched lazily on first API call to avoid blocking.
    // The plugin already has them in memory from its native init.
    _initialized = true;
    Log.info(_tag, 'Ready');
  }

  /// Ensure auth headers are set before making requests.
  Future<void> _ensureHeaders() async {
    if (_dio.options.headers.containsKey('Authorization')) return;
    try {
      final devToken = await _musicKit.requestDeveloperToken();
      final userToken = await _musicKit.requestUserToken(devToken);
      final storefront = await _musicKit.currentCountryCode;
      _dio.options.headers['Authorization'] = 'Bearer $devToken';
      if (userToken.isNotEmpty) {
        _dio.options.headers['Music-User-Token'] = userToken;
      }
      _dio.options.baseUrl =
          'https://api.music.apple.com/v1/catalog/$storefront';
      Log.info(_tag, 'Headers set', data: {'storefront': storefront});
    } on Exception catch (e) {
      Log.error(_tag, 'Failed to set headers', exception: e);
    }
  }

  /// Search the Apple Music catalog for albums matching [query].
  Future<List<AppleMusicAlbum>> searchAlbums(
    String query, {
    int limit = 25,
  }) async {
    await _ensureHeaders();
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/search',
        queryParameters: {
          'term': query,
          'types': 'albums',
          'limit': limit,
        },
      );

      final results = response.data?['results'] as Map<String, dynamic>?;
      final albumsData = results?['albums'] as Map<String, dynamic>?;
      final data = albumsData?['data'] as List<dynamic>? ?? [];

      return data.map<AppleMusicAlbum>(_parseAlbum).toList();
    } on DioException catch (e) {
      Log.error(
        _tag,
        'Search failed',
        data: {'query': query, 'status': '${e.response?.statusCode}'},
      );
      return [];
    }
  }

  /// Batch-fetch multiple albums by ID (max 25 per request).
  Future<List<AppleMusicAlbum>> getAlbums(List<String> albumIds) async {
    if (albumIds.isEmpty) return [];
    await _ensureHeaders();

    final results = <AppleMusicAlbum>[];
    for (var i = 0; i < albumIds.length; i += 25) {
      final batch = albumIds.sublist(
        i,
        (i + 25).clamp(0, albumIds.length),
      );
      try {
        final response = await _dio.get<Map<String, dynamic>>(
          '/albums',
          queryParameters: {'ids': batch.join(',')},
        );
        final data = response.data?['data'] as List<dynamic>? ?? [];
        for (final e in data) {
          results.add(_parseAlbum(e));
        }
      } on DioException catch (e) {
        Log.warn(
          _tag,
          'Batch album fetch failed',
          data: {
            'count': '${batch.length}',
            'status': '${e.response?.statusCode}',
          },
        );
      }
    }
    return results;
  }

  /// Get a single album by ID.
  Future<AppleMusicAlbum?> getAlbum(String albumId) async {
    await _ensureHeaders();
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/albums/$albumId',
      );
      final data = response.data?['data'] as List<dynamic>?;
      if (data == null || data.isEmpty) return null;
      return _parseAlbum(data[0]);
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
    await _ensureHeaders();
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/albums/$albumId',
        queryParameters: {'include': 'tracks'},
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
        return AppleMusicTrack(
          id: item['id'] as String,
          name: attrs['name'] as String? ?? '',
          trackNumber: attrs['trackNumber'] as int? ?? 0,
          durationMs: attrs['durationInMillis'] as int? ?? 0,
          artistName: attrs['artistName'] as String?,
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

  // ── Cover request coalescing ──────────────────────────────────────
  // When multiple cards request covers simultaneously (per-card loading),
  // we collect IDs for a short window then fire one batched API call.

  final _pendingCoverIds = <String, Completer<String?>>{};
  Timer? _coverBatchTimer;

  /// Get a single album's cover URL with request coalescing.
  ///
  /// Collects IDs for 50ms, then fires one batched API call.
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
  void cancelCover(String albumId) {
    final completer = _pendingCoverIds.remove(albumId);
    if (completer != null && !completer.isCompleted) {
      completer.complete(null);
    }
  }

  Future<void> _flushCoverBatch(int size) async {
    final batch = Map<String, Completer<String?>>.of(_pendingCoverIds);
    _pendingCoverIds.clear();
    batch.removeWhere((_, c) => c.isCompleted);
    if (batch.isEmpty) return;

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

  // ── Parsing ─────────────────────────────────────────────────────────

  static AppleMusicAlbum _parseAlbum(dynamic e) {
    final item = e as Map<String, dynamic>;
    final attrs =
        item['attributes'] as Map<String, dynamic>? ?? <String, dynamic>{};
    final artwork = attrs['artwork'] as Map<String, dynamic>?;
    return AppleMusicAlbum(
      id: item['id'] as String,
      name: attrs['name'] as String? ?? '',
      artistName: attrs['artistName'] as String? ?? '',
      artworkUrl: artwork?['url'] as String?,
      trackCount: attrs['trackCount'] as int? ?? 0,
      releaseDate: attrs['releaseDate'] as String?,
      genreNames: (attrs['genreNames'] as List<dynamic>?)?.cast<String>() ?? [],
    );
  }
}
