/// Test 3: Settings screen — navigate kid home → parent → settings.
///
/// Bypasses PIN by overriding parentAuthProvider (the router redirect
/// lets us through). Taps the parent button, then "Über lauschi".
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/auth/pin_service.dart';
import 'package:lauschi/features/parent/screens/settings_screen.dart';
import 'package:lauschi/features/player/player_provider.dart';
import 'package:patrol/patrol.dart';

import 'helpers.dart';

void main() {
  patrolTest('settings screen shows support card and providers', ($) async {
    await pumpApp(
      $,
      prefs: {'onboarding_complete': true},
      scope:
          (child) => ProviderScope(
            overrides: [
              mediaSessionHandlerProvider.overrideWithValue(mediaHandler),
              parentAuthProvider.overrideWith(_AlwaysAuth.new),
            ],
            child: child,
          ),
    );

    // Tap parent button — with auth override, the router redirect
    // lets us through to /parent directly (no PIN).
    await $.tester.tap(find.byTooltip('Eltern-Bereich'));
    await pumpFrames($);

    // Should be on parent dashboard. Tap "Über lauschi".
    expect($('Über lauschi'), findsOneWidget);
    await $('Über lauschi').tap();
    await pumpFrames($);

    // Verify the SettingsScreen content.
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect($('lauschi ist ein Herzensprojekt'), findsOneWidget);
    expect($('Kaffee spendieren'), findsOneWidget);
    expect($('GitHub'), findsOneWidget);
    expect($('Spotify'), findsOneWidget);
    expect($('ARD Audiothek'), findsOneWidget);
  });
}

class _AlwaysAuth extends ParentAuth {
  @override
  bool build() => true;
}
