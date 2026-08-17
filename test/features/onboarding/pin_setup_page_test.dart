import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/auth/pin_service.dart';
import 'package:lauschi/core/auth/pin_widgets.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/onboarding/screens/onboarding/widgets/pin_setup_page.dart';
import 'package:mocktail/mocktail.dart';

class _MockPinService extends Mock implements PinService {}

/// Tests for the onboarding PIN setup page's save handling. setPin runs
/// bcrypt in an isolate, so it must show progress; a secure-storage failure
/// must reset the pad instead of trapping the parent on four filled dots.
void main() {
  void tallSurface(WidgetTester tester) {
    // The page fills a phone screen; give the test enough height so the
    // numpad + error text don't overflow the default 600px viewport.
    tester.view.physicalSize = const Size(600, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Widget host(PinService service, VoidCallback onComplete) {
    return ProviderScope(
      overrides: [pinServiceProvider.overrideWith((ref) => service)],
      child: MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(body: PinSetupPage(onComplete: onComplete)),
      ),
    );
  }

  Future<void> enterPin(WidgetTester tester) async {
    for (final d in ['1', '2', '3', '4']) {
      await tester.tap(find.text(d));
      await tester.pump();
    }
  }

  testWidgets('a setPin failure resets the pad with an error, not stuck', (
    tester,
  ) async {
    var completed = false;
    final service = _MockPinService();
    when(() => service.setPin(any())).thenThrow(Exception('keychain locked'));

    tallSurface(tester);
    await tester.pumpWidget(host(service, () => completed = true));
    await tester.pump();

    await enterPin(tester); // first entry
    await enterPin(tester); // confirm -> matches -> setPin throws
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(tester.takeException(), isNull, reason: 'the failure is caught');
    expect(find.textContaining('Speichern fehlgeschlagen'), findsOneWidget);
    expect(completed, isFalse, reason: 'onboarding must not complete');
    expect(
      find.byType(PinNumpad),
      findsOneWidget,
      reason: 'the pad is back so the parent can retry',
    );
  });

  testWidgets('shows a spinner while the PIN is being saved', (tester) async {
    var completed = false;
    final gate = Completer<void>();
    final service = _MockPinService();
    when(() => service.setPin(any())).thenAnswer((_) => gate.future);

    tallSurface(tester);
    await tester.pumpWidget(host(service, () => completed = true));
    await tester.pump();

    await enterPin(tester); // first entry
    await enterPin(tester); // confirm -> setPin gated (pending)
    await tester.pump();

    // Spinner, not pumpAndSettle: it's an infinite animation.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byType(PinNumpad), findsNothing);

    gate.complete();
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(
      completed,
      isTrue,
      reason: 'onComplete fires once the save resolves',
    );
  });
}
