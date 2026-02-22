/// Test 2: Parent PIN gate — tapping parent icon shows PIN screen.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';

import 'helpers.dart';

void main() {
  patrolTest('parent icon navigates to PIN entry', ($) async {
    await pumpApp($, prefs: {'onboarding_complete': true});

    expect($('Meine Hörspiele'), findsOneWidget);

    // Find the parent-mode button by its tooltip.
    final parentButton = find.byTooltip('Eltern-Bereich');
    expect(parentButton, findsOneWidget);

    await $.tester.tap(parentButton);
    await pumpFrames($);

    // PIN screen shows digit buttons (0-9).
    expect($('0'), findsOneWidget);
    expect($('5'), findsOneWidget);
  });
}
