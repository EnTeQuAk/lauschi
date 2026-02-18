import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lauschi/app.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  const dsn = String.fromEnvironment('SENTRY_DSN');

  if (dsn.isEmpty) {
    // No Sentry DSN configured — run without error reporting.
    runApp(const ProviderScope(child: LauschiApp()));
    return;
  }

  await SentryFlutter.init(
    (options) {
      options
        ..dsn = dsn
        ..tracesSampleRate = 0.2
        ..environment = const String.fromEnvironment(
          'SENTRY_ENVIRONMENT',
          defaultValue: 'development',
        );
    },
    appRunner: () => runApp(
      const ProviderScope(child: LauschiApp()),
    ),
  );
}
