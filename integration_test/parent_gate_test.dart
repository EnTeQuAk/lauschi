/// Test 2: Parent PIN gate — tapping parent icon shows PIN screen.
library;

import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  ensureBinding();

  testWidgets('parent icon navigates to PIN entry', (tester) async {
    await pumpApp(tester, prefs: {'onboarding_complete': true});

    // Kid home screen should show "Meine Hörspiele".
    expect(byText('Meine Hörspiele'), findsOneWidget);

    // Find the parent-mode button by its tooltip.
    final parentButton = find.byTooltip('Eltern-Bereich');
    expect(parentButton, findsOneWidget);

    await tester.tap(parentButton);
    // Pump frames for navigation transition.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    // PIN screen shows digit buttons (0-9).
    expect(find.text('0'), findsOneWidget);
    expect(find.text('5'), findsOneWidget);
  });
}
