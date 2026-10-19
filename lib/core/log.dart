import 'dart:developer' as developer;

import 'package:lauschi/core/telemetry/telemetry.dart';

/// Lightweight structured logger.
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
    _log(source, message, level: 500, data: data);
    telemetry.log(LogLevel.debug, source, message, data: data);
  }

  static void info(String source, String message, {Map<String, Object>? data}) {
    _log(source, message, level: 800, data: data);
    telemetry.log(LogLevel.info, source, message, data: data);
  }

  static void warn(String source, String message, {Map<String, Object>? data}) {
    _log(source, message, level: 900, data: data);
    telemetry.log(LogLevel.warning, source, message, data: data);
  }

  static void error(
    String source,
    String message, {
    Object? exception,
    StackTrace? stackTrace,
    Map<String, Object>? data,
  }) {
    _log(source, message, level: 1000, data: data);
    telemetry.log(LogLevel.error, source, message, data: data);
    if (exception != null) {
      telemetry.captureException(
        exception,
        message: '[$source] $message',
        stackTrace: stackTrace,
        data: data,
      );
    }
  }

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
