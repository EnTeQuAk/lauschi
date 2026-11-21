import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/core/ui/undo_snackbar.dart';

/// Pumps a few frames, enough for drift streams and a route transition.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Shows [screen] pushed on top of a start page, the way the parent area
/// opens it, so a test can leave it with back. Snackbars go to the app's
/// root messenger, as in the app.
Future<void> pushScreen(
  WidgetTester tester,
  ProviderContainer container,
  Widget screen,
) async {
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder:
            (context, _) => Scaffold(
              body: TextButton(
                onPressed: () => context.push('/screen'),
                child: const Text('open'),
              ),
            ),
        routes: [GoRoute(path: 'screen', builder: (_, _) => screen)],
      ),
    ],
  );
  addTearDown(router.dispose);
  addTearDown(() => rootScaffoldMessengerKey.currentState?.clearSnackBars());
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        scaffoldMessengerKey: rootScaffoldMessengerKey,
        theme: buildAppTheme(),
        routerConfig: router,
      ),
    ),
  );
  await tester.pump();
  await tester.tap(find.text('open'));
  await settle(tester);
}
