import 'dart:convert';

import 'package:dio/dio.dart';

/// Serves canned JSON per request, recording what was asked for.
///
/// Inject via the `adapter` parameter of the API clients
/// (SpotifyApi, AppleMusicApi) so base URL and interceptors stay
/// production-owned and only the transport is faked.
class FakeHttpAdapter implements HttpClientAdapter {
  FakeHttpAdapter(this.handler);

  final Map<String, dynamic> Function(RequestOptions options) handler;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode(handler(options)),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
