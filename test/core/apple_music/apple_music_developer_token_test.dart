import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/apple_music/apple_music_developer_token.dart';

final _now = DateTime.utc(2026, 11, 19);

/// A JWT-shaped token that expires [left] after [_now]. The app never
/// checks the signature, Apple does.
String _token(Duration left, {String name = 'token'}) {
  String part(Object json) =>
      base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
  final exp = _now.add(left).millisecondsSinceEpoch ~/ 1000;
  return '${part({'alg': 'ES256', 'kid': name})}.${part({'exp': exp})}.sig';
}

/// Serves [body] with [status] as plain text and counts the requests.
class _TokenServer implements HttpClientAdapter {
  _TokenServer(this.body, {this.status = 200});

  final String body;
  final int status;
  final List<Uri> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options.uri);
    return ResponseBody.fromString(body, status);
  }

  @override
  void close({bool force = false}) {}
}

AppleMusicDeveloperToken _source(_TokenServer server) =>
    AppleMusicDeveloperToken(adapter: server, now: () => _now);

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('fetches the published token and keeps it', () async {
    final fresh = _token(const Duration(days: 30));
    final server = _TokenServer('$fresh\n');

    expect(await _source(server).current(), fresh);
    expect(await _source(server).current(), fresh);

    expect(server.requests, [
      Uri.parse('https://auth.lauschi.app/apple_music_token'),
    ]);
  });

  test(
    'fetches a new token once the stored one is close to running out',
    () async {
      final old = _token(const Duration(days: 13), name: 'old');
      final fresh = _token(const Duration(days: 30), name: 'fresh');
      FlutterSecureStorage.setMockInitialValues({
        'apple_music_developer_token': old,
      });

      expect(await _source(_TokenServer(fresh)).current(), fresh);
      expect(await _source(_TokenServer('unused')).current(), fresh);
    },
  );

  test(
    'keeps a stored token that still works when the server is down',
    () async {
      final old = _token(const Duration(days: 3));
      FlutterSecureStorage.setMockInitialValues({
        'apple_music_developer_token': old,
      });

      expect(await _source(_TokenServer('', status: 502)).current(), old);
    },
  );

  test('fails without a stored token when the server is down', () async {
    await expectLater(
      _source(_TokenServer('', status: 502)).current(),
      throwsA(isA<DioException>()),
    );
  });

  test('fails on an expired stored token when the server is down', () async {
    FlutterSecureStorage.setMockInitialValues({
      'apple_music_developer_token': _token(const Duration(days: -1)),
    });

    await expectLater(
      _source(_TokenServer('', status: 502)).current(),
      throwsA(isA<DioException>()),
    );
  });

  test('rejects a page that is not a token, or an expired one', () async {
    for (final body in [
      '<html>Not found</html>',
      _token(const Duration(days: -1)),
    ]) {
      await expectLater(
        _source(_TokenServer(body)).current(),
        throwsA(isA<FormatException>()),
        reason: body,
      );
    }
  });

  test('reads the expiry from the token', () {
    expect(
      expiryOf(_token(const Duration(days: 30))),
      _now.add(const Duration(days: 30)),
    );
    expect(expiryOf('not a token'), isNull);
    expect(expiryOf('a.!!!.c'), isNull);
  });
}
