import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/app_version.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/parent/screens/settings/screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Widget tests for the parent settings screen.
///
/// The "Neustart erforderlich" banner should only appear for settings that
/// are read once at startup (the Sentry toggles). NFC applies live, so
/// flipping it must not claim a restart is needed.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Widget host() {
    return ProviderScope(
      overrides: [appVersionProvider.overrideWith((ref) => 'test')],
      child: MaterialApp(theme: buildAppTheme(), home: const SettingsScreen()),
    );
  }

  testWidgets('toggling NFC applies live and shows no restart banner', (
    tester,
  ) async {
    // Tall viewport so the whole settings list builds (the NFC toggle is at
    // the bottom, and the banner, if it appeared, would be at the top).
    tester.view.physicalSize = const Size(1000, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    expect(
      find.text('NFC-Tags'),
      findsOneWidget,
      reason: 'setup: the NFC toggle is rendered',
    );
    expect(find.textContaining('Neustart erforderlich'), findsNothing);

    await tester.tap(find.widgetWithText(SwitchListTile, 'NFC-Tags'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Neustart erforderlich'),
      findsNothing,
      reason: 'NFC is applied live by NfcListener, so no restart is needed',
    );
  });
}
