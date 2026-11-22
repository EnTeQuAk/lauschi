import 'package:dio/dio.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/telemetry/telemetry.dart';

const _tag = 'AudioFileCheck';

/// Whether an episode's audio file is still on its server.
enum AudioFileStatus {
  /// The server has the file.
  present,

  /// The server says the file doesn't exist (404 or 410).
  gone,

  /// No answer either way: offline, a timeout, or any other status.
  unknown,
}

/// Asks an audio file's server whether the file is still there.
///
/// ARD Sounds keeps listing some episodes as published, audio URL and all,
/// long after their files were deleted from the CDN (in November 2026 that
/// was every Betthupferl episode from 2022). Neither the API nor just_audio
/// tells you: the API still lists the episode, and just_audio reports a
/// missing file as a generic source error without the HTTP status. Only the
/// file's own server knows.
class AudioFileCheck {
  AudioFileCheck()
    : _dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 10),
          // Every status is an answer here, not an exception.
          validateStatus: (_) => true,
        ),
      ) {
    telemetry.instrument(_dio);
  }

  final Dio _dio;

  /// Asks with HEAD, and with a one-byte GET where the server doesn't
  /// answer HEAD.
  Future<AudioFileStatus> check(String url) async {
    try {
      var status = (await _dio.head<void>(url)).statusCode;
      if (status == 405 || status == 501) {
        final response = await _dio.get<ResponseBody>(
          url,
          options: Options(
            headers: {'Range': 'bytes=0-0'},
            responseType: ResponseType.stream,
          ),
        );
        // A server that ignores the range sends the whole file, so drop
        // the body unread.
        await response.data?.stream.listen(null).cancel();
        status = response.statusCode;
      }
      final result = switch (status) {
        404 || 410 => AudioFileStatus.gone,
        final s? when s >= 200 && s < 300 => AudioFileStatus.present,
        _ => AudioFileStatus.unknown,
      };
      Log.info(
        _tag,
        'Checked',
        data: {'status': '$status', 'result': result.name},
      );
      return result;
    } on DioException catch (e) {
      Log.info(_tag, 'No answer', data: {'error': '${e.type}'});
      return AudioFileStatus.unknown;
    }
  }
}
