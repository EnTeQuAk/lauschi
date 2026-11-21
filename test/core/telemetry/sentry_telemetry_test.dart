import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/telemetry/sentry_telemetry.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

/// `tool/strip_sentry.sh` deletes this file along with
/// `sentry_telemetry.dart`, so the store builds still analyze.
void main() {
  testWidgets('navigation breadcrumbs leave out the route arguments', (
    tester,
  ) async {
    final crumbs = <Breadcrumb>[];
    final hub = Hub(
      SentryFlutterOptions(dsn: 'https://public@sentry.invalid/1')
        ..beforeBreadcrumb = (crumb, hint) {
          if (crumb != null) crumbs.add(crumb);
          return crumb;
        },
    );
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        navigatorObservers: [SentryTelemetry.navigatorObserver(hub: hub)],
        home: const SizedBox(),
      ),
    );

    // go_router hands a location's query values to its page as arguments.
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(
          name: '/',
          arguments: {'code': 'secret-user-token'},
        ),
        builder: (_) => const SizedBox(),
      ),
    );
    await tester.pumpAndSettle();

    final navigation = crumbs.where((c) => c.category == 'navigation').toList();
    expect(navigation, isNotEmpty);
    expect(
      navigation.map((c) => c.data.toString()).join(),
      isNot(contains('secret-user-token')),
    );
    expect(navigation.last.data?['to'], '/');
  });
}
