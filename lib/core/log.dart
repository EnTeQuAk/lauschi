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
  // TODO(#cleanup): revert to Sentry-silent debug once pause issue is resolved.
  static void debug(
    String source,
    String message, {
    Map<String, Object>? data,
  }) {
    _log(source, message, level: 500, data: data);
    unawaited(_sentryLog(source, message, level: 'debug', data: data));
    _breadcrumb(source, message, level: SentryLevel.debug, data: data);
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
      // Attach the human-readable message and structured data to the event
      // itself, not just the breadcrumb, so the Sentry issue isn't titled by
      // the bare exception.toString() with no context.
      unawaited(
        Sentry.captureException(
          exception,
          stackTrace: stackTrace,
          message: SentryMessage(_fmt(source, message)),
          withScope: (scope) async {
            if (data != null) {
              await scope.setContexts(
                'log_data',
                data.map((k, v) => MapEntry(k, v.toString())),
              );
            }
          },
        ),
      );
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
    if (data != null)
      for (final e in data.entries)
        e.key: SentryAttribute.string(e.value.toString()),
    // Injected last so a caller's data key named 'source' can't clobber the
    // real source tag.
    'source': SentryAttribute.string(source),
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
      'debug' => Sentry.logger.debug(msg, attributes: attrs),
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
    final formatted = '[$source] $message$suffix';
    developer.log(formatted, name: 'lauschi', level: level);
    // Also goes to adb logcat as I/flutter. developer.log only shows
    // in the attached Dart debugger, not in logcat.
    // ignore: avoid_print
    print('lauschi: $formatted');
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
