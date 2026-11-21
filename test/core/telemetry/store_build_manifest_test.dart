import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Flutter only adds the INTERNET permission to debug and profile builds,
/// so a release build gets it from the app manifest or from a plugin's.
/// The Sentry SDK used to bring it in, and the store builds remove Sentry
/// with `tool/strip_sentry.sh`, so v2026.11.2 shipped without network
/// access. The app manifest declares it itself so no plugin decides that.
void main() {
  test('the app manifest declares the INTERNET permission', () {
    final manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();

    expect(
      manifest,
      contains('<uses-permission android:name="android.permission.INTERNET"/>'),
    );
  });
}
