import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lauschi/app.dart';
import 'package:lauschi/core/settings/debug_settings.dart';
import 'package:lauschi/core/telemetry/telemetry.dart';
import 'package:lauschi/features/onboarding/screens/onboarding_provider.dart';
import 'package:lauschi/features/player/media_session_handler.dart';
import 'package:lauschi/features/player/player_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Lock phones to portrait; tablets can rotate freely. Read via the
  // implicit view (nullable): this early at cold start there may be no view
  // yet, or its size may still be zero. When the size is unknown, skip the
  // lock rather than risk pinning a tablet to portrait (shortestSide 0 < 600).
  final view = WidgetsBinding.instance.platformDispatcher.implicitView;
  final shortestSide =
      (view?.physicalSize.shortestSide ?? 0) / (view?.devicePixelRatio ?? 1);
  if (shortestSide > 0 && shortestSide < 600) {
    await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  }

  // Initialize media session for lock screen / notification controls.
  final mediaHandler = await AudioService.init<MediaSessionHandler>(
    builder: MediaSessionHandler.new,
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'app.lauschi.lauschi.audio',
      androidNotificationChannelName: 'Wiedergabe',
      androidNotificationOngoing: true,
    ),
  );

  // Read prefs once, before the first frame. The onboarding flag seeds its
  // provider so the router's first redirect has the real value (no kid-home
  // flash before a new user is bounced to onboarding).
  final prefs = await SharedPreferences.getInstance();
  final onboardingDone = prefs.getBool(onboardingCompleteKey) ?? false;

  final overrides = [
    mediaSessionHandlerProvider.overrideWithValue(mediaHandler),
    onboardingCompletePreloadProvider.overrideWithValue(onboardingDone),
  ];

  await telemetry.runApp(
    ProviderScope(overrides: overrides, child: const LauschiApp()),
    // User-controlled diagnostics preferences (from the prefs read above).
    // Replay options are init-time only and can't be changed at runtime.
    settings: DebugSettings.fromPrefs(prefs),
  );
}
