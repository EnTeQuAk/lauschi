import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/features/onboarding/screens/onboarding/widgets/connect_providers_page.dart';

void main() {
  group('discoverIllustration', () {
    test('a build without Spotify shows no Spotify bubble', () {
      expect(
        discoverIllustration(spotify: false),
        'assets/images/branding/lauschi-discover-ard-apple-music.png',
      );
    });

    test('a build with Spotify shows all three providers', () {
      expect(
        discoverIllustration(spotify: true),
        'assets/images/branding/lauschi-discover.png',
      );
    });

    test('both illustrations ship with the app', () {
      for (final spotify in [true, false]) {
        final asset = discoverIllustration(spotify: spotify);
        expect(File(asset).existsSync(), isTrue, reason: asset);
      }
    });
  });
}
