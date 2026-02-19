import 'dart:async' show unawaited;
import 'dart:developer' as developer;

import 'package:sentry_flutter/sentry_flutter.dart';

/// Lightweight structured logger.
///
/// - `dart:developer` log: visible in DevTools / `flutter logs`
/// - Sentry structured log (`Sentry.logger`): visible in Sentry Logs tab
/// - Sentry breadcrumb: trail shown on every Sentry error event
///
/// [error] additionally captures the exception as a Sentry event.
abstract final class Log {
  static void debug(
    String source,
    String message, {
    Map<String, Object>? data,
  }) {
    _log(source, message, level: 500, data: data);
    // debug is intentionally not forwarded to Sentry to keep noise down.
  }

  static void info(String source, String message, {Map<String, Object>? data}) {
    _log(source, message, level: 800, data: data);
    unawaited(_sentryLog(source, message, level: 'info', data: data));
    _breadcrumb(source, message, level: SentryLevel.info, data: data);
  }

  static void warn(String source, String message, {Map<String, Object>? data}) {
    _log(source, message, level: 900, data: data);
    unawaited(_sentryLog(source, message, level: 'warn', data: data));
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
    unawaited(_sentryLog(source, message, level: 'error', data: data));
    _breadcrumb(source, message, level: SentryLevel.error, data: data);
    if (exception != null) {
      unawaited(Sentry.captureException(exception, stackTrace: stackTrace));
    }
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  static String _fmt(String source, String message) => '[$source] $message';

  static Map<String, SentryAttribute> _attrs(
    String source,
    Map<String, Object>? data,
  ) => {
    'source': SentryAttribute.string(source),
    if (data != null)
      for (final e in data.entries)
        e.key: SentryAttribute.string(e.value.toString()),
  };

  /// Async wrapper so callers can use [unawaited] without fighting
  /// [FutureOr<void>] directly.
  static Future<void> _sentryLog(
    String source,
    String message, {
    required String level,
    Map<String, Object>? data,
  }) async {
    final attrs = _attrs(source, data);
    final msg = _fmt(source, message);
    final result = switch (level) {
      'info' => Sentry.logger.info(msg, attributes: attrs),
      'warn' => Sentry.logger.warn(msg, attributes: attrs),
      _ => Sentry.logger.error(msg, attributes: attrs),
    };
    await result;
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
    unawaited(
      Sentry.addBreadcrumb(
        Breadcrumb(
          category: source,
          message: message,
          level: level,
          data: data?.map((k, v) => MapEntry(k, v.toString())),
        ),
      ),
    );
  }
}
