import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/log.dart';

void main() {
  group('redactQuery', () {
    test('hides the Apple Music user token in the callback', () {
      final uri = Uri.parse(
        'lauschi://apple-music-callback?code=secret-user-token&state=abc123&storefront=de',
      );

      final redacted = redactQuery(uri);

      expect(redacted, isNot(contains('secret-user-token')));
      expect(redacted, isNot(contains('abc123')));
      expect(
        redacted,
        'lauschi://apple-music-callback?code=redacted&state=redacted&storefront=redacted',
      );
    });

    test('hides a token in the fragment', () {
      final uri = Uri.parse('lauschi://callback#access_token=secret');

      expect(redactQuery(uri), 'lauschi://callback');
    });

    test('keeps a link without query as it is', () {
      final uri = Uri.parse('lauschi://callback');

      expect(redactQuery(uri), 'lauschi://callback');
    });
  });

  test('Log redacts every link it is given', () {
    final lines = <String>[];
    runZoned(
      () => Log.info(
        'DeepLink',
        'Received',
        data: {
          'uri': Uri.parse('lauschi://apple-music-callback?code=secret-token'),
        },
      ),
      zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, line) => lines.add(line),
      ),
    );

    expect(lines.join('\n'), isNot(contains('secret-token')));
    expect(lines.join('\n'), contains('code=redacted'));
  });
}
