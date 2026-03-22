import 'package:dio/dio.dart';
import 'package:lauschi/core/log.dart';

const _tag = 'AppleMusicStream';

/// Result of resolving a song's stream from Apple's webPlayback API.
class StreamResolution {
  const StreamResolution({required this.hlsUrl, required this.licenseUrl});
  final String hlsUrl;
  final String licenseUrl;
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
  /// if the song can't be resolved.
  Future<StreamResolution?> resolveStream(String songId) async {
    if (_developerToken == null || _musicUserToken == null) {
      Log.warn(_tag, 'Not configured');
      return null;
    }

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
    } on DioException catch (e) {
      Log.error(
        _tag,
        'Stream resolve failed',
        data: {'songId': songId, 'status': '${e.response?.statusCode}'},
      );
      return null;
    }
  }

  Map<String, String> _buildHeaders() {
    return {
      'Authorization': 'Bearer $_developerToken',
      'Media-User-Token': _musicUserToken!,
      'Origin': 'https://music.apple.com',
      'Referer': 'https://music.apple.com/',
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
          'AppleWebKit/537.36 (KHTML, like Gecko) '
          'Chrome/130.0.0.0 Safari/537.36',
    };
  }
}
