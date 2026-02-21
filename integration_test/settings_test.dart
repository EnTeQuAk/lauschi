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

import 'helpers.dart';

void main() {
  ensureBinding();

  testWidgets('settings screen shows support card and providers', (
    tester,
  ) async {
    await pumpApp(
      tester,
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
    await tester.tap(find.byTooltip('Eltern-Bereich'));
    await pumpFrames(tester);

    // Should be on parent dashboard. Tap "Über lauschi".
    expect(byText('Über lauschi'), findsOneWidget);
    await tester.tap(find.text('Über lauschi'));
    await pumpFrames(tester);

    // Verify the SettingsScreen content.
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(byText('lauschi ist ein Herzensprojekt'), findsOneWidget);
    expect(byText('Kaffee spendieren'), findsOneWidget);
    expect(byText('GitHub'), findsOneWidget);
    expect(byText('Spotify'), findsOneWidget);
    expect(byText('ARD Audiothek'), findsOneWidget);
  });
}

class _AlwaysAuth extends ParentAuth {
  @override
  bool build() => true;
}
