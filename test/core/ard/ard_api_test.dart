import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/ard/ard_api.dart';

/// Serves a single canned JSON body (any shape, not just a map), so the
/// client can be driven with malformed responses.
class _JsonAdapter implements HttpClientAdapter {
  _JsonAdapter(this.body);

  final Object body;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromString(
    jsonEncode(body),
    200,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );

  @override
  void close({bool force = false}) {}
}

ArdApi _apiWith(HttpClientAdapter adapter) => ArdApi(adapter: adapter);

void main() {
  group('ArdApi response hardening', () {
    test('getKidsShows returns empty on a non-map response body', () async {
      // A 200 carrying a JSON array (an HTML error page decoded oddly, a
      // proxy interstitial) would make a cast to Map<String, dynamic> throw
      // a TypeError, an Error that escapes every handler. It must degrade
      // to an empty result, not crash the fetch.
      final api = _apiWith(_JsonAdapter(<dynamic>[1, 2, 3]));

      expect(await api.getKidsShows(), isEmpty);
    });

    test('getKidsShows skips a malformed node', () async {
      final api = _apiWith(
        _JsonAdapter({
          'data': {
            'programSets': {
              'nodes': [
                {'id': 1, 'title': 'Maus'},
                'not-a-map',
                {'id': 2, 'title': 'Sandmann'},
              ],
            },
          },
        }),
      );

      final shows = await api.getKidsShows();

      expect(shows.map((s) => s.title), ['Maus', 'Sandmann']);
    });

    test('getItems skips a malformed node', () async {
      final api = _apiWith(
        _JsonAdapter({
          'data': {
            'items': {
              'nodes': [
                {'id': 10, 'title': 'Folge 1'},
                42,
                {'id': 11, 'title': 'Folge 2'},
              ],
              'pageInfo': {'hasNextPage': false, 'endCursor': null},
              'totalCount': 2,
            },
          },
        }),
      );

      final page = await api.getItems(programSetId: '999');

      expect(page.items.map((i) => i.title), ['Folge 1', 'Folge 2']);
    });
  });
}
