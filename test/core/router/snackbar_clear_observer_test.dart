import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/router/app_router.dart';

/// [SnackBarClearObserver] clears stale snackbars when navigating forward,
/// but must not clear on a pop: the delete-then-pop undo flows show their
/// "Rückgängig" snackbar for the screen they pop back to.
void main() {
  testWidgets('clears on push but preserves a snackbar across a pop', (
    tester,
  ) async {
    final navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navKey,
        navigatorObservers: [SnackBarClearObserver(navKey)],
        home: const Scaffold(body: Center(child: Text('home'))),
      ),
    );

    // Forward navigation wipes a leftover snackbar.
    final messenger = ScaffoldMessenger.of(navKey.currentContext!)
      ..showSnackBar(const SnackBar(content: Text('stale')));
    await tester.pump();
    expect(find.text('stale'), findsOneWidget);

    unawaited(
      navKey.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('page2')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('stale'), findsNothing, reason: 'push clears');

    // A snackbar shown right before popping back survives the pop.
    messenger.showSnackBar(const SnackBar(content: Text('undo-candidate')));
    await tester.pump();
    navKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(
      find.text('undo-candidate'),
      findsOneWidget,
      reason: 'a pop must not clear the just-shown undo snackbar',
    );

    // Clean up the snackbar timer before teardown.
    messenger.clearSnackBars();
    await tester.pump();
  });
}
