import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/features/parent/screens/settings/widgets/provider_attribution.dart';

void main() {
  group('buildProviderAttributionSentence', () {
    test('ARD only (App Store build)', () {
      final sentence = buildProviderAttributionSentence(
        spotifyEnabled: false,
        appleMusicEnabled: false,
      );
      expect(sentence, contains('ARD Audiothek'));
      expect(sentence, isNot(contains('Spotify')));
      expect(sentence, isNot(contains('Apple Music')));
      expect(sentence, contains('kein offizielles Angebot der ARD'));
      expect(sentence, endsWith('Mehr Hörspiele auf '));
    });

    test('ARD + Spotify (Spotify-only build)', () {
      final sentence = buildProviderAttributionSentence(
        spotifyEnabled: true,
        appleMusicEnabled: false,
      );
      expect(sentence, contains('ARD Audiothek und Spotify'));
      expect(sentence, isNot(contains('Apple Music')));
      expect(sentence, contains('kein offizielles Angebot dieser Anbieter'));
    });

    test('ARD + Apple Music (Apple-only build)', () {
      final sentence = buildProviderAttributionSentence(
        spotifyEnabled: false,
        appleMusicEnabled: true,
      );
      expect(sentence, contains('ARD Audiothek und Apple Music'));
      expect(sentence, isNot(contains('Spotify')));
      expect(sentence, contains('kein offizielles Angebot dieser Anbieter'));
    });

    test('all three providers (tester build)', () {
      final sentence = buildProviderAttributionSentence(
        spotifyEnabled: true,
        appleMusicEnabled: true,
      );
      // Comma between first two, "und" before the last (German list joining).
      expect(sentence, contains('ARD Audiothek, Spotify und Apple Music'));
      expect(sentence, contains('kein offizielles Angebot dieser Anbieter'));
      expect(sentence, endsWith('Mehr Hörspiele auf '));
    });

    test('uses correct German brand spelling for Apple Music', () {
      // Apple's developer guidelines require "Apple Music", never
      // "iTunes" or just "Apple".
      final sentence = buildProviderAttributionSentence(
        spotifyEnabled: false,
        appleMusicEnabled: true,
      );
      expect(sentence, contains('Apple Music'));
      expect(sentence, isNot(contains('iTunes')));
    });
  });
}
