/// Integration tests for the onboarding flow and parent PIN gate.
///
/// Tests the first-run experience (welcome → PIN setup → kid home)
/// and the parent mode entry/exit cycle.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers.dart';

void main() {
  patrolTest(
    'onboarding: welcome → PIN setup → kid home',
    ($) async {
      // Fresh app, no onboarding_complete flag.
      await pumpApp($);
      await pumpFrames($);

      // Should be on the welcome page.
      expect(find.text('lauschi'), findsOneWidget);
      expect(find.text('Dein Hörspiel-Player'), findsOneWidget);

      // Tap "Los geht's" to proceed.
      final startButton = find.byKey(const Key('onboarding_start'));
      expect(startButton, findsOneWidget);
      await $.tap(startButton);
      await pumpFrames($);

      // If streaming providers are enabled, we land on the providers
      // page. Tap "Weiter" to skip it.
      if (find.text('Weiter').evaluate().isNotEmpty) {
        await $.tap(find.text('Weiter'));
        await pumpFrames($);
      }

      // Should be on PIN setup page.
      expect(find.text('Eltern-PIN festlegen'), findsOneWidget);

      // Enter PIN: 1-2-3-4
      await $.tap(find.text('1'));
      await $.tap(find.text('2'));
      await $.tap(find.text('3'));
      await $.tap(find.text('4'));
      await pumpFrames($);

      // Should ask to confirm PIN.
      expect(find.text('PIN bestätigen'), findsOneWidget);

      // Confirm: 1-2-3-4
      await $.tap(find.text('1'));
      await $.tap(find.text('2'));
      await $.tap(find.text('3'));
      await $.tap(find.text('4'));
      await pumpFrames($, count: 15);

      // Should land on kid home screen.
      expect(find.text('Meine Hörspiele'), findsOneWidget);

      // Onboarding should be marked complete (won't show again).
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('onboarding_complete'), isTrue);
    },
  );

  patrolTest(
    'onboarding PIN mismatch shows error and resets',
    ($) async {
      await pumpApp($);
      await pumpFrames($);

      // Navigate to PIN setup.
      await $.tap(find.byKey(const Key('onboarding_start')));
      await pumpFrames($);
      if (find.text('Weiter').evaluate().isNotEmpty) {
        await $.tap(find.text('Weiter'));
        await pumpFrames($);
      }

      expect(find.text('Eltern-PIN festlegen'), findsOneWidget);

      // Enter PIN: 1-2-3-4
      await $.tap(find.text('1'));
      await $.tap(find.text('2'));
      await $.tap(find.text('3'));
      await $.tap(find.text('4'));
      await pumpFrames($);

      // Confirm with WRONG pin: 5-6-7-8
      await $.tap(find.text('5'));
      await $.tap(find.text('6'));
      await $.tap(find.text('7'));
      await $.tap(find.text('8'));
      await pumpFrames($);

      // Should show error and reset back to "PIN festlegen".
      expect(find.text('Eltern-PIN festlegen'), findsOneWidget);

      // Should NOT have completed onboarding.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('onboarding_complete'), isNull);
    },
  );

  patrolTest(
    'parent PIN gate: enter → access parent mode → exit to kid mode',
    ($) async {
      // App with onboarding complete. PIN is set via the onboarding
      // flow (FlutterSecureStorage), so we run onboarding first to
      // set a real PIN, then test the gate.
      await pumpApp($);
      await pumpFrames($);

      // Run through onboarding to set PIN 1-2-3-4.
      await $.tap(find.byKey(const Key('onboarding_start')));
      await pumpFrames($);
      if (find.text('Weiter').evaluate().isNotEmpty) {
        await $.tap(find.text('Weiter'));
        await pumpFrames($);
      }
      for (final d in [1, 2, 3, 4]) {
        await $.tap(find.text('$d'));
      }
      await pumpFrames($);
      for (final d in [1, 2, 3, 4]) {
        await $.tap(find.text('$d'));
      }
      await pumpFrames($, count: 15);

      // Should be on kid home now.
      expect(find.text('Meine Hörspiele'), findsOneWidget);

      // Tap settings gear to enter parent mode.
      final settingsButton = find.byKey(const Key('parent_button'));
      expect(settingsButton, findsOneWidget);
      await $.tap(settingsButton);
      await pumpFrames($);

      // Should be on PIN entry screen.
      expect(find.text('PIN eingeben'), findsOneWidget);

      // Enter correct PIN: 1-2-3-4
      for (final d in [1, 2, 3, 4]) {
        await $.tap(find.text('$d'));
      }
      await pumpFrames($, count: 15);

      // Should be on parent dashboard.
      expect(find.text('Einstellungen'), findsOneWidget);

      // Exit parent mode.
      final exitButton = find.byKey(const Key('exit_parent_mode'));
      expect(exitButton, findsOneWidget);
      await $.tap(exitButton);
      await pumpFrames($, count: 15);

      // Should be back on kid home.
      expect(find.text('Meine Hörspiele'), findsOneWidget);
    },
  );
}
