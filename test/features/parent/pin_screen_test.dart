import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/auth/pin_service.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/parent/screens/pin_screen.dart';
import 'package:mocktail/mocktail.dart';

class _MockPinService extends Mock implements PinService {}

/// Tests for the PIN entry screen's failure handling.
///
/// A secure-storage failure during verify used to leave the pad stuck on
/// four filled dots (the length guard blocked further input) with the error
/// escaping uncaught. It must reset so the parent can retry.
void main() {
  testWidgets('a verify failure resets the pad instead of getting stuck', (
    tester,
  ) async {
    final service = _MockPinService();
    when(
      () => service.verifyPin(any()),
    ).thenThrow(Exception('keychain locked'));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [pinServiceProvider.overrideWith((ref) => service)],
        child: MaterialApp(theme: buildAppTheme(), home: const PinScreen()),
      ),
    );
    await tester.pumpAndSettle();

    Future<void> enter(List<String> digits) async {
      for (final d in digits) {
        await tester.tap(find.text(d));
        await tester.pump();
      }
      await tester.pumpAndSettle();
    }

    // First attempt fails and must reset the pad.
    await enter(['1', '2', '3', '4']);
    // Second attempt is only reachable if the pad actually reset.
    await enter(['5', '6', '7', '8']);

    expect(
      tester.takeException(),
      isNull,
      reason: 'the storage failure is caught, not thrown to the zone',
    );
    verify(() => service.verifyPin(any())).called(2);
  });
}
