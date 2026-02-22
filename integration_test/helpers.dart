/// Shared helpers for integration tests.
///
/// Provides a simplified app bootstrap that initializes platform
/// dependencies and pumps the widget tree on a real device.
library;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lauschi/app.dart';
import 'package:lauschi/features/player/media_session_handler.dart';
import 'package:lauschi/features/player/player_provider.dart';
import 'package:patrol/patrol.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The initialized media handler, available after [initServices].
late MediaSessionHandler mediaHandler;
var _initialized = false;

/// One-time init for platform services that need a running engine.
Future<void> initServices() async {
  if (_initialized) return;
  mediaHandler = await AudioService.init<MediaSessionHandler>(
    builder: MediaSessionHandler.new,
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'app.lauschi.lauschi.test',
      androidNotificationChannelName: 'Test',
    ),
  );
  _initialized = true;
}

/// Pump the app and give it time to settle.
///
/// Uses explicit frame pumping instead of `pumpAndSettle` which hangs
/// when the app has ongoing async work (WebView init, connectivity, etc).
///
/// Pass [scope] to wrap the app in a custom [ProviderScope] with overrides.
Future<void> pumpApp(
  PatrolIntegrationTester $, {
  Map<String, Object> prefs = const {},
  ProviderScope Function(Widget child)? scope,
}) async {
  await initServices();
  SharedPreferences.setMockInitialValues(prefs);

  const app = LauschiApp();

  final baseOverrides = [
    mediaSessionHandlerProvider.overrideWithValue(mediaHandler),
  ];

  Widget widget;
  if (scope != null) {
    widget = scope(app);
  } else {
    widget = ProviderScope(overrides: baseOverrides, child: app);
  }

  await $.pumpWidget(widget);

  // Pump a few frames to let providers resolve and the router settle.
  // Don't use pumpAndSettle — the app has ongoing async work that
  // prevents it from ever "settling".
  for (var i = 0; i < 10; i++) {
    await $.pump(const Duration(milliseconds: 200));
  }
}

/// Pump several frames to let navigation and providers settle.
Future<void> pumpFrames(PatrolIntegrationTester $, {int count = 10}) async {
  for (var i = 0; i < count; i++) {
    await $.pump(const Duration(milliseconds: 200));
  }
}
