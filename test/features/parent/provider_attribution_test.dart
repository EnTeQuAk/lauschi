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
      // Singular disclaimer: "der ARD" (dative), not "dieser Anbieter"
      // (plural) because only one provider is mentioned.
      expect(sentence, contains('kein offizielles Angebot der ARD'));
      // The trailing space is intentional: the UI puts the clickable
      // "ardaudiothek.de" link immediately after this sentence and
      // there's no CSS-level spacing between the TextSpan and the
      // WidgetSpan. Dropping the space would run them together.
      expect(
        sentence,
        endsWith('Mehr Hörspiele auf '),
        reason:
            'trailing space before ardaudiothek.de link is intentional — '
            'see buildProviderAttributionSentence docstring',
      );
    });

    test('ARD + Spotify (Spotify-only build)', () {
      final sentence = buildProviderAttributionSentence(
        spotifyEnabled: true,
        appleMusicEnabled: false,
      );
      expect(sentence, contains('ARD Audiothek und Spotify'));
      expect(sentence, isNot(contains('Apple Music')));
      // Plural disclaimer: two providers listed, so "dieser Anbieter".
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
      expect(
        sentence,
        endsWith('Mehr Hörspiele auf '),
        reason: 'trailing space before ardaudiothek.de link is intentional',
      );
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
