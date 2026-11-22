import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/ard/audio_file_check.dart';

/// Real HTTP clients, even where a widget test binding in the same isolate
/// installed its own overrides that answer every request with 400.
class _RealHttp extends HttpOverrides {}

/// A local server standing in for a CDN: answers HEAD with [headStatus]
/// and GET with [getStatus], and records the methods it was asked with.
class _Cdn {
  _Cdn._(this._server, this.headStatus, this.getStatus) {
    _server.listen((request) async {
      methods.add(request.method);
      request.response.statusCode =
          request.method == 'HEAD' ? headStatus : getStatus;
      if (request.method == 'GET') request.response.write('ID3');
      await request.response.close();
    });
  }

  static Future<_Cdn> start({required int head, int get = 200}) async =>
      _Cdn._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0), head, get);

  final HttpServer _server;
  final int headStatus;
  final int getStatus;
  final List<String> methods = [];

  String get url => 'http://127.0.0.1:${_server.port}/episode.mp3';

  Future<void> close() => _server.close(force: true);
}

Future<AudioFileStatus> _check(String url) =>
    HttpOverrides.runWithHttpOverrides(
      () => AudioFileCheck().check(url),
      _RealHttp(),
    );

void main() {
  for (final (head, expected) in [
    (200, AudioFileStatus.present),
    (404, AudioFileStatus.gone),
    (410, AudioFileStatus.gone),
    (403, AudioFileStatus.unknown),
    (500, AudioFileStatus.unknown),
  ]) {
    test('a $head answer to HEAD means ${expected.name}', () async {
      final cdn = await _Cdn.start(head: head);
      addTearDown(cdn.close);

      expect(await _check(cdn.url), expected);
      expect(cdn.methods, ['HEAD']);
    });
  }

  for (final (get, expected) in [
    (206, AudioFileStatus.present),
    (404, AudioFileStatus.gone),
  ]) {
    test('a server without HEAD is asked with a ranged GET, '
        '$get means ${expected.name}', () async {
      final cdn = await _Cdn.start(head: 405, get: get);
      addTearDown(cdn.close);

      expect(await _check(cdn.url), expected);
      expect(cdn.methods, ['HEAD', 'GET']);
    });
  }

  test('a server that does not answer means unknown', () async {
    // Bind and close at once, so nothing listens on the port.
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final url = 'http://127.0.0.1:${server.port}/episode.mp3';
    await server.close(force: true);

    expect(await _check(url), AudioFileStatus.unknown);
  });
}
