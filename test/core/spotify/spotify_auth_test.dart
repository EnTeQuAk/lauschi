import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/spotify/spotify_auth.dart';
import 'package:mocktail/mocktail.dart';

class _MockDio extends Mock implements Dio {}

class _MockStorage extends Mock implements FlutterSecureStorage {}

void main() {
  late _MockDio dio;
  late _MockStorage storage;
  late SpotifyAuth auth;

  setUp(() {
    dio = _MockDio();
    storage = _MockStorage();
    auth = SpotifyAuth(storage: storage, dio: dio);

    // Default storage stubs (writes succeed silently).
    when(
      () => storage.write(key: any(named: 'key'), value: any(named: 'value')),
    ).thenAnswer((_) async {});
    when(
      () => storage.read(key: any(named: 'key')),
    ).thenAnswer((_) async => null);
  });

  setUpAll(() {
    registerFallbackValue(RequestOptions());
    registerFallbackValue(Options());
  });

  group('refresh', () {
    test('throws SpotifyGrantExpiredException on invalid_grant', () {
      when(
        () => dio.post<Map<String, dynamic>>(
          any(),
          data: any(named: 'data'),
          options: any(named: 'options'),
        ),
      ).thenThrow(
        DioException(
          requestOptions: RequestOptions(path: '/api/token'),
          response: Response(
            requestOptions: RequestOptions(path: '/api/token'),
            statusCode: 400,
            data: <String, dynamic>{'error': 'invalid_grant'},
          ),
          type: DioExceptionType.badResponse,
        ),
      );

      expect(
        () => auth.refresh('stale-refresh-token'),
        throwsA(isA<SpotifyGrantExpiredException>()),
      );
    });

    test('throws SpotifyAuthException on network errors', () {
      when(
        () => dio.post<Map<String, dynamic>>(
          any(),
          data: any(named: 'data'),
          options: any(named: 'options'),
        ),
      ).thenThrow(
        DioException(
          requestOptions: RequestOptions(path: '/api/token'),
          type: DioExceptionType.connectionError,
        ),
      );

      expect(
        () => auth.refresh('some-refresh-token'),
        throwsA(isA<SpotifyAuthException>()),
      );
    });

    test('throws SpotifyAuthException on connection timeout', () {
      when(
        () => dio.post<Map<String, dynamic>>(
          any(),
          data: any(named: 'data'),
          options: any(named: 'options'),
        ),
      ).thenThrow(
        DioException(
          requestOptions: RequestOptions(path: '/api/token'),
          type: DioExceptionType.connectionTimeout,
        ),
      );

      expect(
        () => auth.refresh('some-refresh-token'),
        throwsA(isA<SpotifyAuthException>()),
      );
    });

    test('rethrows DioException for non-grant server errors', () {
      when(
        () => dio.post<Map<String, dynamic>>(
          any(),
          data: any(named: 'data'),
          options: any(named: 'options'),
        ),
      ).thenThrow(
        DioException(
          requestOptions: RequestOptions(path: '/api/token'),
          response: Response(
            requestOptions: RequestOptions(path: '/api/token'),
            statusCode: 500,
            data: <String, dynamic>{'error': 'server_error'},
          ),
          type: DioExceptionType.badResponse,
        ),
      );

      expect(
        () => auth.refresh('some-refresh-token'),
        throwsA(isA<DioException>()),
      );
    });

    test('does not treat other 400 errors as invalid_grant', () {
      when(
        () => dio.post<Map<String, dynamic>>(
          any(),
          data: any(named: 'data'),
          options: any(named: 'options'),
        ),
      ).thenThrow(
        DioException(
          requestOptions: RequestOptions(path: '/api/token'),
          response: Response(
            requestOptions: RequestOptions(path: '/api/token'),
            statusCode: 400,
            data: <String, dynamic>{'error': 'invalid_client'},
          ),
          type: DioExceptionType.badResponse,
        ),
      );

      expect(
        () => auth.refresh('some-refresh-token'),
        throwsA(
          isA<DioException>().having(
            (e) => (e.response?.data as Map)['error'],
            'error',
            'invalid_client',
          ),
        ),
      );
    });
  });

  group('SpotifyTokens', () {
    test('isRefreshTokenExpiringSoon is false when authorizedAt is null', () {
      final tokens = SpotifyTokens(
        accessToken: 'a',
        refreshToken: 'r',
        expiry: DateTime.now().add(const Duration(hours: 1)),
      );
      expect(tokens.isRefreshTokenExpiringSoon, isFalse);
    });

    test('isRefreshTokenExpiringSoon is false for recent authorization', () {
      final tokens = SpotifyTokens(
        accessToken: 'a',
        refreshToken: 'r',
        expiry: DateTime.now().add(const Duration(hours: 1)),
        authorizedAt: DateTime.now().subtract(const Duration(days: 10)),
      );
      expect(tokens.isRefreshTokenExpiringSoon, isFalse);
      // 180 - 10 = ~170 (±1 due to fractional day within test execution)
      expect(tokens.refreshTokenDaysRemaining, closeTo(170, 1));
    });

    test('isRefreshTokenExpiringSoon is true after 150 days', () {
      final tokens = SpotifyTokens(
        accessToken: 'a',
        refreshToken: 'r',
        expiry: DateTime.now().add(const Duration(hours: 1)),
        authorizedAt: DateTime.now().subtract(const Duration(days: 155)),
      );
      expect(tokens.isRefreshTokenExpiringSoon, isTrue);
      expect(tokens.refreshTokenDaysRemaining, closeTo(25, 1));
    });

    test('refreshTokenDaysRemaining is 0 after 180 days', () {
      final tokens = SpotifyTokens(
        accessToken: 'a',
        refreshToken: 'r',
        expiry: DateTime.now().add(const Duration(hours: 1)),
        authorizedAt: DateTime.now().subtract(const Duration(days: 200)),
      );
      expect(tokens.isRefreshTokenExpiringSoon, isTrue);
      expect(tokens.refreshTokenDaysRemaining, equals(0));
    });

    test('refreshTokenDaysRemaining is null when authorizedAt is null', () {
      final tokens = SpotifyTokens(
        accessToken: 'a',
        refreshToken: 'r',
        expiry: DateTime.now().add(const Duration(hours: 1)),
      );
      expect(tokens.refreshTokenDaysRemaining, isNull);
    });
  });
}
