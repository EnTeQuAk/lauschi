/// Test 1: App launches and renders the expected initial screen.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';

import 'helpers.dart';

void main() {
  patrolTest('fresh app shows onboarding screen', ($) async {
    await pumpApp($);

    expect($('lauschi'), findsOneWidget);
    expect($("Los geht's"), findsOneWidget);
  });

  patrolTest('completed onboarding shows kid home', ($) async {
    await pumpApp($, prefs: {'onboarding_complete': true});

    expect($('Meine Hörspiele'), findsOneWidget);
  });
}
