import 'package:dio/dio.dart';
import 'package:lauschi/core/log.dart';

const _tag = 'AppleMusicStream';

/// Resolves Apple Music song IDs to playable HLS stream URLs.
///
/// Uses Apple's webPlayback endpoint (same as music.apple.com web player).
/// Downloads the HLS playlist and rewrites the encryption method tag from
/// ISO-23001-7 (which ExoPlayer doesn't recognize) to SAMPLE-AES-CTR
/// (functionally identical, just a different name for CENC encryption).
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
  Map<String, String> get streamHeaders => _buildHeaders();

  /// Result of resolving a song's stream.
  String? lastLicenseUrl;

  /// Resolve a song ID to an HLS stream URL.
  ///
  /// Returns the HLS playlist URL for the song, or null if unavailable.
  /// Also sets [lastLicenseUrl] from the response.
  Future<String?> resolveStreamUrl(String songId) async {
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

      // Check for failure.
      final failureType = data['failureType'] as String?;
      if (failureType != null) {
        final msg = data['customerMessage'] as String? ?? failureType;
        Log.warn(_tag, 'webPlayback failed', data: {'failure': msg});
        return null;
      }

      // Extract stream URL from songList.
      final songList = data['songList'] as List<dynamic>?;
      if (songList == null || songList.isEmpty) {
        Log.warn(_tag, 'No songs in response');
        return null;
      }

      final song = songList[0] as Map<String, dynamic>;

      // Extract the DRM license server URL.
      lastLicenseUrl = song['hls-key-server-url'] as String?;

      final assets = song['assets'] as List<dynamic>?;
      if (assets == null || assets.isEmpty) {
        Log.warn(_tag, 'No assets in song');
        return null;
      }

      // Pick the best available stream URL.
      String? streamUrl;
      for (final asset in assets) {
        final assetMap = asset as Map<String, dynamic>;
        final flavor = assetMap['flavor'] as String? ?? '';
        final url = assetMap['URL'] as String?;

        // Prefer standard quality AAC (ctrp256).
        if (url != null && flavor.contains('ctrp256')) {
          streamUrl = url;
          break;
        }
        streamUrl ??= url;
      }

      if (streamUrl != null) {
        Log.info(_tag, 'Resolved stream', data: {'songId': songId});
      }

      return streamUrl;
    } on DioException catch (e) {
      Log.error(
        _tag,
        'Stream resolve failed',
        data: {
          'songId': songId,
          'status': '${e.response?.statusCode}',
        },
      );
      return null;
    }
  }

  /// Download an HLS playlist and rewrite the encryption method tag.
  ///
  /// Apple uses METHOD=ISO-23001-7 for CENC encryption. ExoPlayer's
  /// HLS parser only recognizes SAMPLE-AES-CTR (same thing, different name).
  /// Returns the rewritten playlist content as a string.
  Future<String?> fetchAndRewritePlaylist(String playlistUrl) async {
    try {
      final response = await _dio.get<String>(
        playlistUrl,
        options: Options(
          headers: _buildHeaders(),
          responseType: ResponseType.plain,
        ),
      );

      var content = response.data;
      if (content == null) return null;

      if (content.contains('ISO-23001-7')) {
        Log.debug(_tag, 'Rewriting ISO-23001-7 → SAMPLE-AES-CTR');
        content = content.replaceAll('ISO-23001-7', 'SAMPLE-AES-CTR');
      }

      return content;
    } on DioException catch (e) {
      Log.error(
        _tag,
        'Playlist fetch failed',
        data: {'status': '${e.response?.statusCode}'},
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
