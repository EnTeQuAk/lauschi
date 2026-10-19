import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart' as widgets show runApp;
import 'package:flutter/widgets.dart';
import 'package:lauschi/core/feature_flags.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/settings/debug_settings.dart';
import 'package:lauschi/core/telemetry/telemetry_backend.dart';
import 'package:sentry_dio/sentry_dio.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

/// The app's telemetry in tester builds.
const TelemetryBackend telemetry = SentryTelemetry();

/// Reports to Sentry when `ENABLE_SENTRY` is set and a `SENTRY_DSN` given.
///
/// Logs and breadcrumbs go to the Sentry SDK either way, which drops them
/// while it isn't initialized.
final class SentryTelemetry implements TelemetryBackend {
  const SentryTelemetry();

  @override
  Future<void> runApp(Widget app, {required DebugSettings settings}) async {
    const dsn = String.fromEnvironment('SENTRY_DSN');

    if (!FeatureFlags.enableSentry || dsn.isEmpty) {
      Log.debug('App', 'Starting without Sentry');
      widgets.runApp(app);
      return;
    }

    const env = String.fromEnvironment(
      'SENTRY_ENVIRONMENT',
      defaultValue: 'development',
    );
    const isDev = env == 'development';

    await SentryFlutter.init(
      (options) {
        options
          ..dsn = dsn
          ..environment = env
          // TODO(#211): reduce to 0.2 once iOS OAuth is stable
          ..tracesSampleRate = 1.0
          // Structured logs, visible in Sentry Logs tab.
          ..enableLogs = true
          // Session replay, respects user preference; error captures always on.
          ..replay.sessionSampleRate =
              settings.replayEnabled ? (isDev ? 1.0 : 0.0) : 0.0
          ..replay.onErrorSampleRate = settings.replayEnabled ? 1.0 : 0.0
          // Privacy masking lives on options.privacy, not options.replay.
          ..privacy.maskAllText = settings.maskAllText
          ..privacy.maskAllImages = settings.maskAllImages;
      },
      appRunner: () {
        Log.info(
          'App',
          'Starting',
          data: {
            'env': env,
            'replay': settings.replayEnabled,
            'maskText': settings.maskAllText,
            'maskImages': settings.maskAllImages,
          },
        );
        // SentryWidget is required for session replay.
        widgets.runApp(SentryWidget(child: app));
      },
    );
  }

  @override
  List<NavigatorObserver> get navigatorObservers => [SentryNavigatorObserver()];

  @override
  void instrument(Dio dio) {
    if (FeatureFlags.enableSentry) dio.addSentry();
  }

  @override
  void log(
    LogLevel level,
    String source,
    String message, {
    Map<String, Object>? data,
  }) {
    unawaited(_structuredLog(level, source, message, data));
    unawaited(
      Sentry.addBreadcrumb(
        Breadcrumb(
          category: source,
          message: message,
          level: _breadcrumbLevels[level],
          data: data?.map((k, v) => MapEntry(k, v.toString())),
        ),
      ),
    );
  }

  @override
  void captureException(
    Object exception, {
    required String message,
    StackTrace? stackTrace,
    Map<String, Object>? data,
  }) {
    // Attach the human-readable message and structured data to the event
    // itself, not just the breadcrumb, so the Sentry issue isn't titled by
    // the bare exception.toString() with no context.
    unawaited(
      Sentry.captureException(
        exception,
        stackTrace: stackTrace,
        message: SentryMessage(message),
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

  static const _breadcrumbLevels = {
    LogLevel.debug: SentryLevel.debug,
    LogLevel.info: SentryLevel.info,
    LogLevel.warning: SentryLevel.warning,
    LogLevel.error: SentryLevel.error,
  };

  /// Async wrapper so callers can use [unawaited] without fighting
  /// [FutureOr<void>] directly.
  static Future<void> _structuredLog(
    LogLevel level,
    String source,
    String message,
    Map<String, Object>? data,
  ) async {
    final attrs = {
      if (data != null)
        for (final e in data.entries)
          e.key: SentryAttribute.string(e.value.toString()),
      // Injected last so a caller's data key named 'source' can't clobber
      // the real source tag.
      'source': SentryAttribute.string(source),
    };
    final msg = '[$source] $message';
    final result = switch (level) {
      LogLevel.debug => Sentry.logger.debug(msg, attributes: attrs),
      LogLevel.info => Sentry.logger.info(msg, attributes: attrs),
      LogLevel.warning => Sentry.logger.warn(msg, attributes: attrs),
      LogLevel.error => Sentry.logger.error(msg, attributes: attrs),
    };
    await result;
  }
}
