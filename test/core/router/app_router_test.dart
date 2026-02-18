import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/router/app_router.dart';
import 'package:lauschi/core/theme/app_theme.dart';

Widget _buildApp(ProviderContainer container) {
  return UncontrolledProviderScope(
    container: container,
    child: Consumer(
      builder: (context, ref, _) {
        final router = ref.watch(appRouterProvider);
        return MaterialApp.router(
          theme: buildAppTheme(),
          routerConfig: router,
        );
      },
    ),
  );
}

void main() {
  testWidgets('app starts on kid home route', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(_buildApp(container));
    await tester.pumpAndSettle();

    // Label appears in AppBar + body — both confirm we're on the right route
    expect(find.text('Kid Home'), findsAtLeastNWidgets(1));
  });

  testWidgets('navigating to /player renders player placeholder', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(_buildApp(container));
    await tester.pumpAndSettle();

    container.read(appRouterProvider).go(AppRoutes.player);
    await tester.pumpAndSettle();

    expect(find.text('Player'), findsAtLeastNWidgets(1));
  });

  testWidgets('navigating to /parent renders parent dashboard placeholder', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(_buildApp(container));
    await tester.pumpAndSettle();

    container.read(appRouterProvider).go(AppRoutes.parentDashboard);
    await tester.pumpAndSettle();

    expect(find.text('Parent Dashboard'), findsAtLeastNWidgets(1));
  });
}
