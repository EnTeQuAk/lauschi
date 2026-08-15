import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/apple_music/apple_music_stream_resolver.dart';

/// Serves a scripted sequence of (status, body) responses, one per call,
/// recording how many requests were made. A non-2xx status makes Dio
/// throw a DioException, the way a real 5xx/timeout would.
class _SeqAdapter implements HttpClientAdapter {
  _SeqAdapter(this.steps);

  final List<({int status, Map<String, dynamic> body})> steps;
  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final step = steps[calls < steps.length ? calls : steps.length - 1];
    calls++;
    return ResponseBody.fromString(
      jsonEncode(step.body),
      step.status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

AppleMusicStreamResolver _resolverWith(_SeqAdapter adapter) =>
    AppleMusicStreamResolver(adapter: adapter)
      ..configure(developerToken: 'dev', musicUserToken: 'user');

final _validStream = {
  'songList': [
    {
      'hls-key-server-url': 'https://license',
      'assets': [
        {'flavor': '28:ctrp256', 'URL': 'https://hls'},
      ],
    },
  ],
};

void main() {
  group('AppleMusicStreamResolver.resolveStream', () {
    test('a permanent failure does not retry', () async {
      // No songs is a permanent result, not a transient blip. Retrying
      // it just burns a second and an extra round-trip on the playback
      // hot path before failing.
      final adapter = _SeqAdapter([
        (status: 200, body: {'songList': <dynamic>[]}),
      ]);

      final result = await _resolverWith(adapter).resolveStream('song-1');

      expect(result, isNull);
      expect(adapter.calls, 1, reason: 'permanent failure must not retry');
    });

    test('a transient 5xx retries once then succeeds', () async {
      final adapter = _SeqAdapter([
        (status: 503, body: <String, dynamic>{}),
        (status: 200, body: _validStream),
      ]);

      final result = await _resolverWith(adapter).resolveStream('song-1');

      expect(result, isNotNull);
      expect(result!.hlsUrl, 'https://hls');
      expect(adapter.calls, 2, reason: 'a 5xx is transient and retries once');
    });

    test('an auth failureType throws even with a German message', () {
      // Detection keys off the language-independent failureType code, so
      // a DACH-storefront German customerMessage still triggers re-auth.
      final adapter = _SeqAdapter([
        (
          status: 200,
          body: {
            'failureType': 'AUTH_TOKEN_EXPIRED',
            'customerMessage': 'Nicht autorisiert',
          },
        ),
      ]);

      expect(
        () => _resolverWith(adapter).resolveStream('song-1'),
        throwsA(isA<AppleMusicAuthExpiredException>()),
      );
    });

    test(
      'a non-auth failureType is not misread as expiry from its text',
      () async {
        // The dropped English substring checks used to throw on any message
        // containing "authenticate". A non-auth failureType must now resolve
        // to null (generic failure), not a spurious auth-expiry.
        final adapter = _SeqAdapter([
          (
            status: 200,
            body: {
              'failureType': 'CONTENT_UNAVAILABLE',
              'customerMessage': 'Please authenticate again',
            },
          ),
        ]);

        final result = await _resolverWith(adapter).resolveStream('song-1');

        expect(result, isNull);
      },
    );
  });
}
