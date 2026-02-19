import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lauschi/app.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/settings/debug_settings.dart';
import 'package:lauschi/features/player/media_session_handler.dart';
import 'package:lauschi/features/player/player_provider.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
    Log.debug('App', 'Starting without Sentry (no DSN configured)');
    runApp(ProviderScope(overrides: overrides, child: const LauschiApp()));
    return;
  }

  const env = String.fromEnvironment(
    'SENTRY_ENVIRONMENT',
    defaultValue: 'development',
  );
  const isDev = env == 'development';

  // Read user-controlled diagnostics preferences before Sentry init —
  // replay options are init-time only and can't be changed at runtime.
  final prefs = await SharedPreferences.getInstance();
  final debugSettings = DebugSettings.fromPrefs(prefs);

  await SentryFlutter.init(
    (options) {
      options
        ..dsn = dsn
        ..environment = env
        ..tracesSampleRate = isDev ? 1.0 : 0.2
        // Structured logs — visible in Sentry Logs tab.
        ..enableLogs = true
        // Session replay — respects user preference; error captures always on.
        ..replay.sessionSampleRate =
            debugSettings.replayEnabled ? (isDev ? 1.0 : 0.0) : 0.0
        ..replay.onErrorSampleRate =
            debugSettings.replayEnabled ? 1.0 : 0.0
        // Privacy masking lives on options.privacy, not options.replay.
        ..privacy.maskAllText = debugSettings.maskAllText
        ..privacy.maskAllImages = debugSettings.maskAllImages;
    },
    appRunner: () {
      Log.info('App', 'Starting', data: {
        'env': env,
        'replay': debugSettings.replayEnabled,
        'maskText': debugSettings.maskAllText,
        'maskImages': debugSettings.maskAllImages,
      });
      return runApp(
        // SentryWidget is required for session replay.
        SentryWidget(
          child: ProviderScope(overrides: overrides, child: const LauschiApp()),
        ),
      );
    },
  );
}
