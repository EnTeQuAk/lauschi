import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lauschi/app.dart';
import 'package:lauschi/features/player/media_session_handler.dart';
import 'package:lauschi/features/player/player_provider.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize media session for lock screen / notification controls.
  final mediaHandler = await AudioService.init<MediaSessionHandler>(
    builder: MediaSessionHandler.new,
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'app.lauschi.lauschi.audio',
      androidNotificationChannelName: 'Wiedergabe',
      androidNotificationOngoing: true,
    ),
  );

  final overrides = [
    mediaSessionHandlerProvider.overrideWithValue(mediaHandler),
  ];

  const dsn = String.fromEnvironment('SENTRY_DSN');

  if (dsn.isEmpty) {
    // No Sentry DSN configured — run without error reporting.
    runApp(ProviderScope(overrides: overrides, child: const LauschiApp()));
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
    appRunner:
        () => runApp(
          ProviderScope(overrides: overrides, child: const LauschiApp()),
        ),
  );
}
