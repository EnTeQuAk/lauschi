import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/ard/ard_api.dart';

import '../../helpers/fake_http_adapter.dart';

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

    test('getItem returns null for an item with no playable audio', () async {
      // getItem's contract is "not found or no audio"; an item that exists
      // but carries an empty audios list is unplayable and must read as
      // null, not a non-null ArdItem with bestAudioUrl == null.
      final api = _apiWith(
        _JsonAdapter({
          'data': {
            'item': {'id': 5, 'title': 'Stumm', 'audios': <dynamic>[]},
          },
        }),
      );

      expect(await api.getItem('5'), isNull);
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

  group('getPublishDates', () {
    test('looks up many episodes in one request', () async {
      final adapter = FakeHttpAdapter(
        (_) => {
          'data': {
            'items': {
              'nodes': [
                {'id': '11', 'publishDate': '2025-06-30T00:00:00+02:00'},
                {'id': '12', 'publishDate': 'not a date'},
                'not-a-map',
              ],
            },
          },
        },
      );
      final api = _apiWith(adapter);

      final dates = await api.getPublishDates(['11', '12', '13']);

      expect(dates, {'11': DateTime.parse('2025-06-30T00:00:00+02:00')});
      final body = adapter.requests.single.data as Map<String, dynamic>;
      final variables = body['variables'] as Map<String, dynamic>;
      // ARD's id filter takes integers.
      expect(variables['ids'], [11, 12, 13]);
    });

    // No episodes and no answer are different things: the date backfill
    // marks itself done after the first and has to retry after the second.
    for (final (name, body) in <(String, Object)>[
      ('no data', {'data': null}),
      ('no items', {'data': <String, dynamic>{}}),
      ('a body that is no map', <dynamic>['<html>']),
    ]) {
      test('an answer with $name throws', () async {
        final api = _apiWith(_JsonAdapter(body));

        await expectLater(
          api.getPublishDates(['11']),
          throwsA(isA<ArdApiException>()),
        );
      });
    }
  });

  group('getStoryOrder', () {
    test('looks up the story and show of many episodes at once', () async {
      final adapter = FakeHttpAdapter(
        (_) => {
          'data': {
            'items': {
              'nodes': [
                {
                  'id': 11,
                  'groupId': 'luise',
                  'programSet': {'showType': 'INFINITE_SERIES'},
                },
                {
                  'id': 12,
                  'groupId': null,
                  'programSet': {'showType': 'FINITE_SERIES'},
                },
              ],
            },
          },
        },
      );
      final api = _apiWith(adapter);

      final order = await api.getStoryOrder(['11', '12', '13']);

      expect(order, {
        '11': (storyId: 'luise', latestFirst: true),
        '12': (storyId: null, latestFirst: false),
      });
      final body = adapter.requests.single.data as Map<String, dynamic>;
      expect((body['variables'] as Map<String, dynamic>)['ids'], [11, 12, 13]);
    });

    test('an answer without items throws', () async {
      final api = _apiWith(_JsonAdapter({'data': <String, dynamic>{}}));

      await expectLater(
        api.getStoryOrder(['11']),
        throwsA(isA<ArdApiException>()),
      );
    });
  });
}
