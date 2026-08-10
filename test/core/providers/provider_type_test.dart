import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/providers/provider_type.dart';

void main() {
  group('ProviderType.fromUri', () {
    test('resolves every provider from its own albumUri', () {
      for (final provider in ProviderType.values) {
        expect(ProviderType.fromUri(provider.albumUri('abc')), provider);
      }
    });

    test('resolves every provider from its own trackUri', () {
      for (final provider in ProviderType.values) {
        expect(ProviderType.fromUri(provider.trackUri('abc')), provider);
      }
    });

    test('resolves ARD item URIs to ardAudiothek', () {
      expect(
        ProviderType.fromUri('ard:item:urn:ard:episode:123'),
        ProviderType.ardAudiothek,
      );
    });

    test('throws on an unknown prefix', () {
      expect(() => ProviderType.fromUri('bogus:album:1'), throwsArgumentError);
    });

    test('throws on a URI without a provider prefix', () {
      expect(() => ProviderType.fromUri('abc123'), throwsArgumentError);
    });
  });
}
