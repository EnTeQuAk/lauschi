import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
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
