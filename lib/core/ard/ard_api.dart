import 'package:dio/dio.dart';
import 'package:lauschi/core/ard/ard_config.dart';
import 'package:lauschi/core/ard/ard_models.dart';
import 'package:lauschi/core/log.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'ard_api.g.dart';

const _tag = 'ArdApi';

/// Standard fields included in all Item queries.
const _itemFields = '''
  id title titleClean synopsis duration publishDate endDate
  episodeNumber isPublished groupId
  image { url url1X1 }
  programSet { title }
  group { title type count }
  audios { url mimeType }
''';

/// Client for the ARD Audiothek GraphQL API.
///
/// No authentication required. All queries are POST to /graphql.
/// See https://api.ardaudiothek.de/graphiql for the schema explorer.
class ArdApi {
  ArdApi()
    : _dio = Dio(
        BaseOptions(
          baseUrl: 'https://api.ardaudiothek.de',
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 15),
        ),
      );

  final Dio _dio;

  /// Get all kids shows (programSets in "Für Kinder" category).
  Future<List<ArdProgramSet>> getKidsShows({int first = 100}) async {
    Log.debug(_tag, 'Fetching kids shows', data: {'first': '$first'});
    final data = await _graphql(
      '''
      query KidsShows(\$first: Int!) {
        programSets(
          first: \$first,
          filter: {
            editorialCategoryId: { equalTo: "${ArdConfig.kidsCategoryId}" },
            numberOfElements: { greaterThan: 0 }
          },
          orderBy: NUMBER_OF_ELEMENTS_DESC
        ) {
          nodes {
            id title synopsis description showType numberOfElements
            lastItemAdded feedUrl
            image { url url1X1 }
            publicationService {
              title brandingColor
              organization { name }
            }
          }
        }
      }
    ''',
      variables: {'first': first},
    );

    final nodes = _extractNodes(data, 'programSets');
    final shows = nodes.map(ArdProgramSet.fromJson).toList();
    Log.info(_tag, 'Kids shows fetched', data: {'count': '${shows.length}'});
    return shows;
  }

  /// Get a single programSet by ID.
  Future<ArdProgramSet?> getProgramSet(String id) async {
    Log.debug(_tag, 'Fetching program set', data: {'id': id});
    final data = await _graphql(
      // ignore: use_raw_strings, raw strings don't support \$ for GraphQL variables.
      '''
      query ProgramSet(\$id: ID!) {
        programSet(id: \$id) {
          id title synopsis description showType numberOfElements
          lastItemAdded feedUrl
          image { url url1X1 }
          publicationService {
            title brandingColor
            organization { name }
          }
        }
      }
    ''',
      variables: {'id': id},
    );

    final node = data?['programSet'] as Map<String, dynamic>?;
    if (node == null) return null;
    return ArdProgramSet.fromJson(node);
  }

  /// Get episodes for a show, with pagination.
  Future<ArdItemPage> getItems({
    required String programSetId,
    int first = 50,
    String? after,
    bool publishedOnly = true,
  }) async {
    Log.debug(_tag, 'Fetching items', data: {
      'programSetId': programSetId,
      'first': '$first',
      if (after != null) 'after': after,
    });
    // All dynamic values passed as GraphQL variables to prevent injection.
    // programSetId is Int in the ARD schema (IntFilter), not String.
    final data = await _graphql(
      '''
      query Items(\$first: Int!, \$after: Cursor, \$programSetId: Int!) {
        items(
          first: \$first,
          after: \$after,
          filter: {
            programSetId: { equalTo: \$programSetId },
            isPublished: { equalTo: true }
          },
          orderBy: PUBLISH_DATE_DESC
        ) {
          nodes { $_itemFields }
          pageInfo { hasNextPage endCursor }
          totalCount
        }
      }
    ''',
      variables: {
        'first': first,
        'programSetId': int.parse(programSetId),
        if (after != null) 'after': after,
      },
    );

    final items = data?['items'] as Map<String, dynamic>? ?? {};
    final nodes =
        (items['nodes'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
    final pageInfo = items['pageInfo'] as Map<String, dynamic>? ?? {};

    final result = ArdItemPage(
      items: nodes.map(ArdItem.fromJson).toList(),
      hasNextPage: pageInfo['hasNextPage'] as bool? ?? false,
      endCursor: pageInfo['endCursor'] as String?,
      totalCount: items['totalCount'] as int? ?? 0,
    );
    Log.debug(_tag, 'Items fetched', data: {
      'programSetId': programSetId,
      'fetched': '${result.items.length}',
      'total': '${result.totalCount}',
      'hasMore': '${result.hasNextPage}',
    });
    return result;
  }

  /// Search for kids items by title.
  Future<List<ArdItem>> searchItems(String query, {int first = 20}) async {
    Log.debug(_tag, 'Searching items', data: {'query': query, 'first': '$first'});
    final data = await _graphql(
      '''
      query Search(\$query: String!, \$first: Int!) {
        items(
          first: \$first,
          filter: {
            title: { includesInsensitive: \$query },
            editorialCategoryId: { equalTo: "${ArdConfig.kidsCategoryId}" },
            isPublished: { equalTo: true }
          },
          orderBy: PUBLISH_DATE_DESC
        ) {
          nodes { $_itemFields }
        }
      }
    ''',
      variables: {'query': query, 'first': first},
    );

    final nodes = _extractNodes(data, 'items');
    final results = nodes.map(ArdItem.fromJson).toList();
    Log.debug(_tag, 'Search results', data: {
      'query': query,
      'count': '${results.length}',
    });
    return results;
  }

  /// Execute a GraphQL query.
  Future<Map<String, dynamic>?> _graphql(
    String query, {
    Map<String, dynamic>? variables,
  }) async {
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '/graphql',
        data: {
          'query': query,
          if (variables != null) 'variables': variables,
        },
      );

      final body = response.data;
      if (body == null) return null;

      final errors = body['errors'] as List<dynamic>?;
      if (errors != null && errors.isNotEmpty) {
        final firstError = errors.first as Map<String, dynamic>;
        final message = firstError['message'] as String? ?? 'Unknown error';
        Log.error(_tag, 'GraphQL error', data: {'message': message});
        throw ArdApiException(message);
      }

      return body['data'] as Map<String, dynamic>?;
    } on DioException catch (e) {
      // Connection errors (no internet, DNS failure) are expected in
      // offline/airplane mode — log at warn, not error.
      if (e.type == DioExceptionType.connectionError ||
          e.type == DioExceptionType.connectionTimeout) {
        Log.warn(
          _tag,
          'Network unavailable',
          data: {'url': e.requestOptions.uri.host},
        );
        throw const ArdApiException(
          'Keine Internetverbindung',
          isNetworkError: true,
        );
      }
      Log.error(_tag, 'Request failed', exception: e);
      throw ArdApiException(
        e.message ?? 'Network error',
        statusCode: e.response?.statusCode,
      );
    }
  }

  List<Map<String, dynamic>> _extractNodes(
    Map<String, dynamic>? data,
    String field,
  ) {
    final container = data?[field] as Map<String, dynamic>? ?? {};
    return (container['nodes'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>();
  }
}

/// Exception thrown by the ARD Audiothek API client.
class ArdApiException implements Exception {
  const ArdApiException(
    this.message, {
    this.statusCode,
    this.isNetworkError = false,
  });

  final String message;
  final int? statusCode;

  /// True for transient connectivity issues (DNS, timeout).
  /// Callers can suppress Sentry reporting for these.
  final bool isNetworkError;

  @override
  String toString() => 'ArdApiException: $message (status: $statusCode)';
}

@Riverpod(keepAlive: true)
ArdApi ardApi(Ref ref) => ArdApi();
