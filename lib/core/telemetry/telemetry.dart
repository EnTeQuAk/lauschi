/// The app's telemetry.
///
/// Tester builds export the Sentry backend from here. The store builds
/// collect no data: `tool/strip_sentry.sh` points this export at
/// `noop_telemetry.dart`, deletes `sentry_telemetry.dart` and removes the
/// Sentry packages, so the SDK isn't in the app at all.
library;

export 'package:lauschi/core/telemetry/sentry_telemetry.dart' show telemetry;
export 'package:lauschi/core/telemetry/telemetry_backend.dart';
