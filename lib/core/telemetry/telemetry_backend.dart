import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:lauschi/core/settings/debug_settings.dart';

/// Severity of a [TelemetryBackend.log] entry.
enum LogLevel { debug, info, warning, error }

/// Where the app sends its errors, logs and request traces.
///
/// Tester builds report to Sentry through `SentryTelemetry`. Store builds
/// collect nothing: `tool/strip_sentry.sh` switches them to
/// `NoopTelemetry` and removes the Sentry SDK from the app.
abstract interface class TelemetryBackend {
  /// Starts [app], with error reporting set up first where it is enabled.
  Future<void> runApp(Widget app, {required DebugSettings settings});

  /// Observers that record navigation, for the router.
  List<NavigatorObserver> get navigatorObservers;

  /// Adds request tracing to [dio].
  void instrument(Dio dio);

  /// Records a log line, and a breadcrumb for later error reports.
  void log(
    LogLevel level,
    String source,
    String message, {
    Map<String, Object>? data,
  });

  /// Reports [exception] with the log [message] and its [data].
  void captureException(
    Object exception, {
    required String message,
    StackTrace? stackTrace,
    Map<String, Object>? data,
  });
}
