import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// app_links hands lauschi:// links to `LauschiApp`. Flutter's own deep
/// linking would push them into the router as well: an OAuth callback then
/// opens the kid home, and its secrets become route arguments that land in
/// Sentry's navigation records.
void main() {
  test('Android leaves lauschi:// links to app_links', () {
    final manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();

    expect(
      manifest,
      matches(
        RegExp(
          r'android:name="flutter_deeplinking_enabled"\s+'
          'android:value="false"',
        ),
      ),
    );
  });

  test('iOS leaves lauschi:// links to app_links', () {
    final plist = File('ios/Runner/Info.plist').readAsStringSync();

    expect(
      plist,
      matches(RegExp(r'<key>FlutterDeepLinkingEnabled</key>\s*<false/>')),
    );
  });
}
