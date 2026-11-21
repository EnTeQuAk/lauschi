import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/ui/phone_portrait_lock.dart';

/// Phones are meant to stay in portrait. The lock used to run in main(),
/// where the display size can still be zero at cold start, and then it
/// silently stayed off, so a phone turned to landscape (#315). Going by
/// the display left it off too: Flutter reports none on Android.
void main() {
  late List<List<String>> requests;

  setUp(() {
    requests = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'SystemChrome.setPreferredOrientations') {
            requests.add((call.arguments as List).cast<String>());
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<void> pumpLock(WidgetTester tester, Size viewSize) async {
    tester.view.physicalSize = viewSize;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const PhonePortraitLock(child: SizedBox()));
    await tester.pump();
  }

  testWidgets('a phone stays in portrait', (tester) async {
    await pumpLock(tester, const Size(822, 1830)); // 411 x 915 dp

    expect(requests, [
      ['DeviceOrientation.portraitUp'],
    ]);
  });

  testWidgets('a tablet turns freely', (tester) async {
    await pumpLock(tester, const Size(2560, 1600)); // 1280 x 800 dp

    expect(requests, [<String>[]]);
  });

  testWidgets('a foldable unlocks when it opens into a tablet', (tester) async {
    await pumpLock(tester, const Size(822, 1830));

    tester.view.physicalSize = const Size(1840, 2208); // 920 x 1104 dp
    await tester.pump();

    expect(requests, [
      ['DeviceOrientation.portraitUp'],
      <String>[],
    ]);
  });

  // A Pixel 9a on Android 16 reports a -1 x -1 display. The test binding
  // can't lay out under a negative display, an empty one stands in.
  testWidgets('a phone whose display Flutter does not know stays in portrait', (
    tester,
  ) async {
    tester.view.display.size = Size.zero;
    addTearDown(tester.view.display.reset);
    await pumpLock(tester, const Size(822, 1830));

    expect(requests, [
      ['DeviceOrientation.portraitUp'],
    ]);
  });

  testWidgets('a view without a size yet locks nothing', (tester) async {
    await pumpLock(tester, Size.zero);

    expect(requests, isEmpty);
  });
}
