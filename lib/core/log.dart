import 'dart:async' show unawaited;
import 'dart:developer' as developer;

import 'package:sentry_flutter/sentry_flutter.dart';

/// Lightweight structured logger.
///
/// Uses `dart:developer` log (shows in DevTools / `flutter logs`) and
/// records breadcrumbs in Sentry when a DSN is configured.
abstract final class Log {
  static void debug(String source, String message, {Map<String, Object>? data}) {
    _log(source, message, level: 500, data: data);
  }

  static void info(String source, String message, {Map<String, Object>? data}) {
    _log(source, message, level: 800, data: data);
    _breadcrumb(source, message, level: SentryLevel.info, data: data);
  }

  static void warn(String source, String message, {Map<String, Object>? data}) {
    _log(source, message, level: 900, data: data);
    _breadcrumb(source, message, level: SentryLevel.warning, data: data);
  }

  static void error(
    String source,
    String message, {
    Object? exception,
    StackTrace? stackTrace,
    Map<String, Object>? data,
  }) {
    _log(source, message, level: 1000, data: data);
    _breadcrumb(source, message, level: SentryLevel.error, data: data);
    if (exception != null) {
      unawaited(Sentry.captureException(exception, stackTrace: stackTrace));
    }
  }

  static void _log(
    String source,
    String message, {
    required int level,
    Map<String, Object>? data,
  }) {
    final suffix = data != null ? '  $data' : '';
    developer.log('[$source] $message$suffix', name: 'lauschi', level: level);
  }

  static void _breadcrumb(
    String source,
    String message, {
    required SentryLevel level,
    Map<String, Object>? data,
  }) {
    unawaited(Sentry.addBreadcrumb(
      Breadcrumb(
        category: source,
        message: message,
        level: level,
        data: data?.map((k, v) => MapEntry(k, v.toString())),
      ),
    ));
  }
}
