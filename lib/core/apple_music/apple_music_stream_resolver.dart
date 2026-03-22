import 'dart:async' show unawaited;

import 'package:dio/dio.dart';
import 'package:lauschi/core/log.dart';

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
/// Uses Apple's webPlayback endpoint (same as music.apple.com web player).
/// This is an undocumented internal API. The DRM is legitimate: device
/// Widevine CDM, Apple's own license server, real subscriber tokens.
class AppleMusicStreamResolver {
  AppleMusicStreamResolver()
    : _dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 15),
        ),
      );

  final Dio _dio;

  String? _developerToken;
  String? _musicUserToken;

  /// Configure with auth tokens. Must be called before resolving streams.
  /// Also pre-warms TLS connections to Apple's servers in the background.
  void configure({
    required String developerToken,
    required String musicUserToken,
  }) {
    _developerToken = developerToken;
    _musicUserToken = musicUserToken;
    // Pre-warm TLS connections. The first TLS handshake to Apple's servers
    // takes 20-50 seconds on some Android devices (Fairphone 6). Subsequent
    // requests reuse the TLS session and are fast (~100ms). By warming up
    // during session restore, the connections are ready when the user taps play.
    unawaited(_prewarmConnections());
  }

  Future<void> _prewarmConnections() async {
    try {
      await Future.wait([
        _dio.head<void>(
          'https://aod-ssl.itunes.apple.com/',
          options: Options(
            headers: _buildHeaders(),
            validateStatus: (_) => true,
            receiveTimeout: const Duration(seconds: 30),
          ),
        ),
        _dio.head<void>(
          'https://play.itunes.apple.com/',
          options: Options(
            headers: _buildHeaders(),
            validateStatus: (_) => true,
            receiveTimeout: const Duration(seconds: 30),
          ),
        ),
      ]);
      Log.info(_tag, 'TLS connections pre-warmed');
    } on Exception catch (e) {
      // Non-fatal. First play will just be slower.
      Log.debug(_tag, 'Pre-warm failed (non-fatal): $e');
    }
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

    // Single retry for transient errors (503, network timeout).
    for (var attempt = 0; attempt < 2; attempt++) {
      final result = await _resolveStreamOnce(songId);
      if (result != null) return result;
      if (attempt == 0) {
        Log.info(_tag, 'Retrying stream resolve for $songId');
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    }
    return null;
  }

  Future<StreamResolution?> _resolveStreamOnce(String songId) async {
    try {
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
        // Auth-related failures: token expired, unauthorized, etc.
        if (failureType.contains('AUTH') ||
            failureType.contains('UNAUTHORIZED') ||
            failureType.contains('TOKEN') ||
            msg.contains('not authorized') ||
            msg.contains('authenticate')) {
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
    } on AppleMusicAuthExpiredException {
      rethrow;
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      Log.error(
        _tag,
        'Stream resolve failed',
        data: {'songId': songId, 'status': '$status'},
      );
      // HTTP 401/403 = token expired or revoked.
      if (status == 401 || status == 403) {
        throw AppleMusicAuthExpiredException(
          'HTTP $status from webPlayback',
        );
      }
      return null;
    }
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
