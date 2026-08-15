import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:lauschi/core/feature_flags.dart';
import 'package:lauschi/core/log.dart';
import 'package:sentry_dio/sentry_dio.dart';

const _tag = 'AppleMusicStream';

/// Result of resolving a song's stream from Apple's webPlayback API.
class StreamResolution {
  const StreamResolution({required this.hlsUrl, required this.licenseUrl});
  final String hlsUrl;
  final String licenseUrl;
}

/// Thrown when the webPlayback API rejects the request due to auth issues.
/// The session should transition to Unauthenticated so the UI prompts re-auth.
class AppleMusicAuthExpiredException implements Exception {
  const AppleMusicAuthExpiredException(this.message);
  final String message;
  @override
  String toString() => 'AppleMusicAuthExpiredException: $message';
}

/// Resolves Apple Music song IDs to playable HLS stream URLs.
///
/// Uses Apple's webPlayback endpoint:
///   POST https://play.music.apple.com/WebObjects/MZPlay.woa/wa/webPlayback
///
/// IMPORTANT: This is an undocumented internal Apple API (same endpoint
/// used by music.apple.com's web player). Apple could change the response
/// format, add rate limiting, or require additional headers without notice.
/// The DRM usage is legitimate: device's Widevine CDM, Apple's own license
/// server, authenticated subscriber tokens. No keys are extracted or leaked.
class AppleMusicStreamResolver {
  /// [adapter] replaces the HTTP transport in tests; base options and
  /// interceptors stay owned by this constructor either way.
  AppleMusicStreamResolver({@visibleForTesting HttpClientAdapter? adapter})
    : _dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 15),
        ),
      ) {
    if (FeatureFlags.enableSentry) _dio.addSentry();
    if (adapter != null) _dio.httpClientAdapter = adapter;
  }

  final Dio _dio;

  String? _developerToken;
  String? _musicUserToken;

  /// Configure with auth tokens. Must be called before resolving streams.
  ///
  /// TLS pre-warming is handled on the Kotlin side (OkHttp) via
  /// setMusicUserToken → AppleMusicDrmCallback.prewarmConnections().
  /// The Kotlin OkHttp client is shared between the DRM callback and
  /// HLS data source, so pre-warming one warms both.
  void configure({
    required String developerToken,
    required String musicUserToken,
  }) {
    _developerToken = developerToken;
    _musicUserToken = musicUserToken;
  }

  /// Headers needed by ExoPlayer to fetch HLS streams and segments.
  Map<String, String> get streamHeaders {
    if (_developerToken == null || _musicUserToken == null) {
      return {};
    }
    return _buildHeaders();
  }

  /// Resolve a song ID to a playable stream.
  ///
  /// Returns the HLS playlist URL and license server URL, or null
  /// if the song can't be resolved. Retries once on transient errors.
  /// Throws [AppleMusicAuthExpiredException] if the token is invalid.
  Future<StreamResolution?> resolveStream(String songId) async {
    if (_developerToken == null || _musicUserToken == null) {
      Log.warn(_tag, 'Not configured');
      return null;
    }

    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        return await _resolveStreamOnce(songId);
      } on DioException catch (e) {
        final status = e.response?.statusCode;
        // HTTP 401/403 = token expired or revoked. Not transient; the
        // session must re-auth.
        if (status == 401 || status == 403) {
          throw AppleMusicAuthExpiredException('HTTP $status from webPlayback');
        }
        Log.error(
          _tag,
          'Stream resolve failed',
          data: {'songId': songId, 'status': '$status'},
        );
        // Retry once, but only for a transient network error (timeout,
        // connection drop, 5xx). A permanent failure returns null from
        // _resolveStreamOnce above without a wasted second retry.
        if (attempt == 0 && _isTransient(e)) {
          Log.info(_tag, 'Retrying stream resolve for $songId');
          await Future<void>.delayed(const Duration(seconds: 1));
          continue;
        }
        return null;
      }
    }
    return null;
  }

  static const _transientTypes = {
    DioExceptionType.connectionError,
    DioExceptionType.connectionTimeout,
    DioExceptionType.receiveTimeout,
    DioExceptionType.sendTimeout,
  };

  static bool _isTransient(DioException e) {
    if (_transientTypes.contains(e.type)) return true;
    final status = e.response?.statusCode;
    return status != null && status >= 500;
  }

  Future<StreamResolution?> _resolveStreamOnce(String songId) async {
    final response = await _dio.post<Map<String, dynamic>>(
      'https://play.music.apple.com/WebObjects/MZPlay.woa/wa/webPlayback',
      data: {'salableAdamId': songId},
      options: Options(
        headers: _buildHeaders(),
        contentType: 'application/json',
      ),
    );

    final data = response.data;
    if (data == null) {
      Log.warn(_tag, 'Empty response');
      return null;
    }

    final failureType = data['failureType'] as String?;
    if (failureType != null) {
      final msg = data['customerMessage'] as String? ?? failureType;
      Log.warn(_tag, 'webPlayback failed', data: {'failure': msg});
      // Rely on the language-independent failureType code, not the
      // localized customerMessage: the app's DACH storefront returns
      // German messages that English substring checks would never match.
      if (failureType.contains('AUTH') ||
          failureType.contains('UNAUTHORIZED') ||
          failureType.contains('TOKEN')) {
        throw AppleMusicAuthExpiredException(msg);
      }
      return null;
    }

    final songList = data['songList'] as List<dynamic>?;
    if (songList == null || songList.isEmpty) {
      Log.warn(_tag, 'No songs in response');
      return null;
    }

    final song = songList[0] as Map<String, dynamic>;
    final licenseUrl = song['hls-key-server-url'] as String? ?? '';

    final assets = song['assets'] as List<dynamic>?;
    if (assets == null || assets.isEmpty) {
      Log.warn(_tag, 'No assets in song');
      return null;
    }

    // Prefer standard quality AAC (ctrp256).
    String? streamUrl;
    for (final asset in assets) {
      final assetMap = asset as Map<String, dynamic>;
      final flavor = assetMap['flavor'] as String? ?? '';
      final url = assetMap['URL'] as String?;

      if (url != null && flavor.contains('ctrp256')) {
        streamUrl = url;
        break;
      }
      streamUrl ??= url;
    }

    if (streamUrl == null) {
      Log.warn(_tag, 'No stream URL in assets');
      return null;
    }

    Log.info(_tag, 'Resolved stream', data: {'songId': songId});
    return StreamResolution(hlsUrl: streamUrl, licenseUrl: licenseUrl);
  }

  Map<String, String> _buildHeaders() {
    return {
      'Authorization': 'Bearer $_developerToken',
      'Media-User-Token': _musicUserToken ?? '',
      'Origin': 'https://music.apple.com',
      'Referer': 'https://music.apple.com/',
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
          'AppleWebKit/537.36 (KHTML, like Gecko) '
          'Chrome/130.0.0.0 Safari/537.36',
    };
  }
}
