import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart' as widgets show runApp;
import 'package:flutter/widgets.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/settings/debug_settings.dart';
import 'package:lauschi/core/telemetry/telemetry_backend.dart';

/// The app's telemetry in store builds.
const TelemetryBackend telemetry = NoopTelemetry();

/// Collects nothing, so the store builds ship without the Sentry SDK.
final class NoopTelemetry implements TelemetryBackend {
  const NoopTelemetry();

  @override
  Future<void> runApp(Widget app, {required DebugSettings settings}) async {
    Log.debug('App', 'Starting without telemetry');
    widgets.runApp(app);
  }

  @override
  List<NavigatorObserver> get navigatorObservers => const [];

  @override
  void instrument(Dio dio) {}

  @override
  void log(
    LogLevel level,
    String source,
    String message, {
    Map<String, Object>? data,
  }) {}

  @override
  void captureException(
    Object exception, {
    required String message,
    StackTrace? stackTrace,
    Map<String, Object>? data,
  }) {}
}
