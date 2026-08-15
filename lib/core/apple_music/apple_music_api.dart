import 'dart:async' show Completer, Timer, unawaited;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:lauschi/core/feature_flags.dart';
import 'package:lauschi/core/log.dart';
import 'package:sentry_dio/sentry_dio.dart';

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
/// Only needs the developer token (JWT generated on-device from .p8 key).
/// Catalog endpoints don't require a Music-User-Token; that's only for
/// personalized endpoints (/v1/me/...) and playback.
class AppleMusicApi {
  /// [adapter] replaces the HTTP transport in tests; base URL and
  /// interceptors stay owned by this constructor either way.
  AppleMusicApi({@visibleForTesting HttpClientAdapter? adapter})
    : _dio = Dio(
        BaseOptions(
          baseUrl: 'https://api.music.apple.com/v1',
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 15),
        ),
      ) {
    if (FeatureFlags.enableSentry) _dio.addSentry();
    if (adapter != null) _dio.httpClientAdapter = adapter;
  }

  final Dio _dio;
  bool _configured = false;

  /// Set the developer token and storefront for API requests.
  /// Called by AppleMusicSession once tokens are available.
  void configure({required String developerToken, required String storefront}) {
    _dio.options.headers['Authorization'] = 'Bearer $developerToken';
    _dio.options.baseUrl = 'https://api.music.apple.com/v1/catalog/$storefront';
    _configured = true;
    Log.info(_tag, 'Configured', data: {'storefront': storefront});
  }

  void _requireConfigured() {
    if (!_configured) {
      throw StateError('AppleMusicApi not configured. Call configure() first.');
    }
  }

  /// Search the Apple Music catalog for albums matching [query].
  Future<List<AppleMusicAlbum>> searchAlbums(
    String query, {
    int limit = 25,
  }) async {
    _requireConfigured();
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

      return data.map(_parseAlbum).whereType<AppleMusicAlbum>().toList();
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
    _requireConfigured();

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
          final album = _parseAlbum(e);
          if (album != null) results.add(album);
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
    _requireConfigured();
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

  /// Get every track of an album, following pagination.
  ///
  /// The tracks relationship is paged; long albums (Kinderlieder
  /// compilations, box sets) span multiple pages and would otherwise
  /// be silently truncated.
  Future<List<AppleMusicTrack>> getAlbumTracks(String albumId) async {
    _requireConfigured();
    const pageSize = 100;
    final tracks = <AppleMusicTrack>[];
    var offset = 0;
    try {
      while (true) {
        final response = await _dio.get<Map<String, dynamic>>(
          '/albums/$albumId/tracks',
          queryParameters: {'limit': pageSize, 'offset': offset},
        );

        final data = response.data?['data'] as List<dynamic>? ?? [];
        tracks.addAll(
          data
              .whereType<Map<String, dynamic>>()
              .map(_parseTrack)
              .whereType<AppleMusicTrack>(),
        );
        if (response.data?['next'] == null || data.isEmpty) break;
        offset += pageSize;
      }
      return tracks;
    } on DioException catch (e) {
      Log.error(
        _tag,
        'Get album tracks failed',
        data: {'albumId': albumId, 'status': '${e.response?.statusCode}'},
      );
      return tracks;
    }
  }

  /// Parse a track, or null when its required id is missing or not a
  /// string. Callers filter the nulls, so one malformed item is skipped
  /// instead of throwing a TypeError that would crash the whole album's
  /// track list (and, via play(), the kid's playback).
  static AppleMusicTrack? _parseTrack(Map<String, dynamic> item) {
    final id = item['id'];
    if (id is! String) return null;
    final attrs =
        item['attributes'] as Map<String, dynamic>? ?? <String, dynamic>{};
    return AppleMusicTrack(
      id: id,
      name: attrs['name'] as String? ?? '',
      trackNumber: attrs['trackNumber'] as int? ?? 0,
      durationMs: attrs['durationInMillis'] as int? ?? 0,
      artistName: attrs['artistName'] as String?,
    );
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

  /// Parse an album, or null when the item is not a map or its required
  /// id is missing or not a string. Callers filter the nulls, so one
  /// malformed item in a search or batch response is skipped instead of
  /// throwing a TypeError that would fail the whole request.
  static AppleMusicAlbum? _parseAlbum(dynamic e) {
    if (e is! Map<String, dynamic>) return null;
    final id = e['id'];
    if (id is! String) return null;
    final attrs =
        e['attributes'] as Map<String, dynamic>? ?? <String, dynamic>{};
    final artwork = attrs['artwork'] as Map<String, dynamic>?;
    return AppleMusicAlbum(
      id: id,
      name: attrs['name'] as String? ?? '',
      artistName: attrs['artistName'] as String? ?? '',
      artworkUrl: artwork?['url'] as String?,
      trackCount: attrs['trackCount'] as int? ?? 0,
      releaseDate: attrs['releaseDate'] as String?,
      genreNames:
          (attrs['genreNames'] as List<dynamic>?)
              ?.whereType<String>()
              .toList() ??
          [],
    );
  }
}
