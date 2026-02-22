/// Test 4: Parent dashboard — verify navigation and manage series.
///
/// Bypasses PIN via parentAuthProvider override to test the dashboard
/// and series management flows.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/auth/pin_service.dart';
import 'package:lauschi/features/player/player_provider.dart';
import 'package:patrol/patrol.dart';

import 'helpers.dart';

void main() {
  patrolTest('parent dashboard shows management options', ($) async {
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

    // Kid home screen.
    expect($('Meine Hörspiele'), findsOneWidget);

    // Tap parent-mode button (bypasses PIN via override).
    await $.tester.tap(find.byTooltip('Eltern-Bereich'));
    await pumpFrames($);

    // Parent dashboard: verify key sections.
    expect($('SAMMLUNG'), findsOneWidget);
    expect($('SERIEN'), findsOneWidget);
    expect($('STREAMING'), findsOneWidget);

    // Navigate to series management.
    await $('Serien verwalten').tap();
    await pumpFrames($);

    // Series management screen loaded.
    expect($('Serien verwalten'), findsOneWidget);
  });
}

class _AlwaysAuth extends ParentAuth {
  @override
  bool build() => true;
}
