import 'dart:developer' as developer;

import 'package:lauschi/core/telemetry/telemetry.dart';

/// [uri] for a log line, with every query value replaced and the fragment
/// dropped. OAuth callbacks carry secrets there: Spotify's authorization
/// code, and for Apple Music the music user token itself.
///
/// Works on the raw query and decodes nothing, since decoding throws on an
/// escape that is no valid UTF-8 and any app can open a lauschi:// link.
String redactQuery(Uri uri) {
  final link = uri.removeFragment();
  if (!link.hasQuery) return '$link';
  final redacted = [
    for (final pair in link.query.split('&'))
      if (pair.isNotEmpty) '${pair.split('=').first}=redacted',
  ].join('&');
  return '${link.replace(query: redacted)}';
}

/// Lightweight structured logger.
///
/// Pass links as [Uri] values in `data`: their query values are redacted
/// (see [redactQuery]).
///
/// - `dart:developer` log: visible in DevTools / `flutter logs`
/// - [telemetry] log and breadcrumb: in tester builds the Sentry Logs tab
///   and the trail shown on every Sentry error event
///
/// [error] additionally reports the exception through [telemetry].
abstract final class Log {
  // TODO(#cleanup): revert to Sentry-silent debug once pause issue is resolved.
  static void debug(
    String source,
    String message, {
    Map<String, Object>? data,
  }) {
    final safe = _redacted(data);
    _log(source, message, level: 500, data: safe);
    telemetry.log(LogLevel.debug, source, message, data: safe);
  }

  static void info(String source, String message, {Map<String, Object>? data}) {
    final safe = _redacted(data);
    _log(source, message, level: 800, data: safe);
    telemetry.log(LogLevel.info, source, message, data: safe);
  }

  static void warn(String source, String message, {Map<String, Object>? data}) {
    final safe = _redacted(data);
    _log(source, message, level: 900, data: safe);
    telemetry.log(LogLevel.warning, source, message, data: safe);
  }

  static void error(
    String source,
    String message, {
    Object? exception,
    StackTrace? stackTrace,
    Map<String, Object>? data,
  }) {
    final safe = _redacted(data);
    _log(source, message, level: 1000, data: safe);
    telemetry.log(LogLevel.error, source, message, data: safe);
    if (exception != null) {
      telemetry.captureException(
        exception,
        message: '[$source] $message',
        stackTrace: stackTrace,
        data: safe,
      );
    }
  }

  /// [data] with every [Uri] value passed through [redactQuery], so a link
  /// handed to the logger never shows its query to logcat or telemetry.
  static Map<String, Object>? _redacted(Map<String, Object>? data) => data?.map(
    (key, value) => MapEntry(key, value is Uri ? redactQuery(value) : value),
  );

  static void _log(
    String source,
    String message, {
    required int level,
    Map<String, Object>? data,
  }) {
    final suffix = data != null ? '  $data' : '';
    final formatted = '[$source] $message$suffix';
    developer.log(formatted, name: 'lauschi', level: level);
    // Also goes to adb logcat as I/flutter. developer.log only shows
    // in the attached Dart debugger, not in logcat.
    // ignore: avoid_print
    print('lauschi: $formatted');
  }
}
