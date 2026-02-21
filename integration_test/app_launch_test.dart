/// Test 1: App launches and renders the expected initial screen.
library;

import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  ensureBinding();

  testWidgets('fresh app shows onboarding screen', (tester) async {
    // No prefs → onboarding_complete defaults to false.
    await pumpApp(tester);

    // The onboarding screen shows "lauschi" branding and a start button.
    expect(byText('lauschi'), findsOneWidget);
    expect(byText("Los geht's"), findsOneWidget);
  });

  testWidgets('completed onboarding shows kid home', (tester) async {
    await pumpApp(tester, prefs: {'onboarding_complete': true});

    // Kid home screen shows the "Meine Hörspiele" heading.
    expect(byText('Meine Hörspiele'), findsOneWidget);
  });
}
