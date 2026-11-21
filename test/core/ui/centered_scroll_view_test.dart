import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/ui/centered_scroll_view.dart';

void main() {
  Future<void> pumpIn(WidgetTester tester, double height) => tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 200,
          height: height,
          child: const CenteredScrollView(
            padding: EdgeInsets.all(48),
            child: SizedBox(width: 20, height: 20, key: Key('child')),
          ),
        ),
      ),
    ),
  );

  testWidgets('centers a child that fits', (tester) async {
    await pumpIn(tester, 400);

    expect(tester.getCenter(find.byKey(const Key('child'))).dy, 200);
  });

  // A window shorter than the padding, as in split screen.
  testWidgets('a window shorter than its padding still lays out', (
    tester,
  ) async {
    await pumpIn(tester, 40);

    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('child')), findsOneWidget);
  });
}
