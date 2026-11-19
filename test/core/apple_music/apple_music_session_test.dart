// mocktail records the stubbed invocation lazily, so its no-arg method and
// getter stubs must stay `when(() => x.foo())` closures, not tearoffs.
// ignore_for_file: unnecessary_lambdas

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/apple_music/apple_music_api.dart';
import 'package:lauschi/core/apple_music/apple_music_developer_token.dart';
import 'package:lauschi/core/apple_music/apple_music_session.dart';
import 'package:lauschi/core/apple_music/apple_music_stream_resolver.dart';
import 'package:lauschi/core/apple_music/apple_music_web_auth.dart';
import 'package:mocktail/mocktail.dart';
import 'package:music_kit/music_kit.dart';

// MusicKit is a singleton with a private constructor, so it can't be
// subclassed; mocktail implements its interface instead. The web auth,
// catalog API, stream resolver and developer token are faked the same way
// so the session's orchestration can be driven without platform channels.
class _FakeMusicKit extends Mock implements MusicKit {}

class _FakeWebAuth extends Mock implements AppleMusicWebAuth {}

class _FakeApi extends Mock implements AppleMusicApi {}

class _FakeResolver extends Mock implements AppleMusicStreamResolver {}

class _FakeDeveloperToken extends Mock implements AppleMusicDeveloperToken {}

/// The Android developer token, served as 'devtoken' unless a test passes
/// its own.
_FakeDeveloperToken _devtoken() {
  final token = _FakeDeveloperToken();
  when(() => token.current()).thenAnswer((_) async => 'devtoken');
  return token;
}

/// Builds a container with the session wired to fakes and a pinned platform.
/// Reading `.notifier` runs build(), which kicks off the async _init; callers
/// stub the _init deps first, then [_settle] to let it reach a terminal state.
({ProviderContainer container, AppleMusicSession session}) _build({
  required _FakeMusicKit musicKit,
  required _FakeWebAuth webAuth,
  required _FakeApi api,
  required _FakeResolver resolver,
  required bool isIOS,
  _FakeDeveloperToken? developerToken,
}) {
  final container = ProviderContainer(
    overrides: [
      appleMusicSessionProvider.overrideWith(
        () => AppleMusicSession(
          musicKit: musicKit,
          api: api,
          streamResolver: resolver,
          webAuth: webAuth,
          developerToken: developerToken ?? _devtoken(),
          isIOS: isIOS,
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  final session = container.read(appleMusicSessionProvider.notifier);
  return (container: container, session: session);
}

/// _init runs async off build(); yield to the event loop until it leaves the
/// initial Loading state so a following connect()/handleCallback doesn't race
/// the restore path.
Future<void> _settle(ProviderContainer container) async {
  for (var i = 0; i < 50; i++) {
    if (container.read(appleMusicSessionProvider) is! AppleMusicLoading) return;
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('AppleMusicSession.handleExpiredToken', () {
    test('on Android, drops stored credentials and re-prompts', () async {
      // A token rejected mid-playback (expired/revoked) must clear the
      // keychain and return to Unauthenticated so the UI prompts re-auth.
      final musicKit = _FakeMusicKit();
      final webAuth = _FakeWebAuth();
      when(() => webAuth.loadStored()).thenAnswer(
        (_) async =>
            const AppleMusicTokens(musicUserToken: 'mut', storefront: 'de'),
      );
      when(() => musicKit.setMusicUserToken('mut')).thenAnswer((_) async {});
      when(() => webAuth.logout()).thenAnswer((_) async {});

      final built = _build(
        musicKit: musicKit,
        webAuth: webAuth,
        api: _FakeApi(),
        resolver: _FakeResolver(),
        isIOS: false,
      );
      await _settle(built.container);
      expect(
        built.container.read(appleMusicSessionProvider),
        isA<AppleMusicAuthenticated>(),
        reason: 'stored token should restore an authenticated session',
      );

      await built.session.handleExpiredToken();

      expect(
        built.container.read(appleMusicSessionProvider),
        isA<AppleMusicUnauthenticated>(),
      );
      verify(() => webAuth.logout()).called(1);
    });

    test(
      'on iOS, returns to Unauthenticated without touching web auth',
      () async {
        // Native MusicKit auth has no local credentials to clear; logout()
        // is Android-only. iOS still drops to Unauthenticated to re-prompt.
        final musicKit = _FakeMusicKit();
        final webAuth = _FakeWebAuth();
        when(
          () => musicKit.authorizationStatus,
        ).thenAnswer((_) async => MusicAuthorizationStatusAuthorized(null));
        when(
          () => musicKit.requestDeveloperToken(),
        ).thenAnswer((_) async => 'devtoken');
        when(() => musicKit.currentCountryCode).thenAnswer((_) async => 'de');

        final built = _build(
          musicKit: musicKit,
          webAuth: webAuth,
          api: _FakeApi(),
          resolver: _FakeResolver(),
          isIOS: true,
        );
        await _settle(built.container);
        expect(
          built.container.read(appleMusicSessionProvider),
          isA<AppleMusicAuthenticated>(),
        );

        await built.session.handleExpiredToken();

        expect(
          built.container.read(appleMusicSessionProvider),
          isA<AppleMusicUnauthenticated>(),
        );
        verifyNever(() => webAuth.logout());
      },
    );

    test('is a no-op when already Unauthenticated', () async {
      // Two playback failures can fire the callback twice; the second must
      // not clear the keychain again or churn state.
      final musicKit = _FakeMusicKit();
      final webAuth = _FakeWebAuth();
      when(() => webAuth.loadStored()).thenAnswer((_) async => null);

      final built = _build(
        musicKit: musicKit,
        webAuth: webAuth,
        api: _FakeApi(),
        resolver: _FakeResolver(),
        isIOS: false,
      );
      await _settle(built.container);
      expect(
        built.container.read(appleMusicSessionProvider),
        isA<AppleMusicUnauthenticated>(),
      );

      await built.session.handleExpiredToken();

      expect(
        built.container.read(appleMusicSessionProvider),
        isA<AppleMusicUnauthenticated>(),
      );
      verifyNever(() => webAuth.logout());
    });
  });

  group('AppleMusicSession.connect', () {
    test(
      'on Android, opens web auth and defers authentication to the callback',
      () async {
        // The deep-link handleCallback owns the token exchange (it has to, for
        // app-kill relaunch). connect() only supplies the dev token and opens
        // the browser; it must not configure or flip to Authenticated itself,
        // or a relaunch double-configures.
        final musicKit = _FakeMusicKit();
        final webAuth = _FakeWebAuth();
        final api = _FakeApi();
        when(() => webAuth.loadStored()).thenAnswer((_) async => null);
        when(() => webAuth.login(developerToken: 'devtoken')).thenAnswer(
          (_) async =>
              const AppleMusicTokens(musicUserToken: 'x', storefront: 'de'),
        );

        final built = _build(
          musicKit: musicKit,
          webAuth: webAuth,
          api: api,
          resolver: _FakeResolver(),
          isIOS: false,
        );
        await _settle(built.container);

        await built.session.connect();

        expect(
          built.container.read(appleMusicSessionProvider),
          isA<AppleMusicLoading>(),
          reason: 'connect keeps a spinner up until the callback authenticates',
        );
        verify(() => webAuth.login(developerToken: 'devtoken')).called(1);
        verifyNever(
          () => api.configure(
            developerToken: any(named: 'developerToken'),
            storefront: any(named: 'storefront'),
          ),
        );
      },
    );

    test(
      'on iOS, native authorization configures the API and authenticates',
      () async {
        final musicKit = _FakeMusicKit();
        final api = _FakeApi();
        when(
          () => musicKit.authorizationStatus,
        ).thenAnswer((_) async => MusicAuthorizationStatusNotDetermined());
        when(
          () => musicKit.requestAuthorizationStatus(),
        ).thenAnswer((_) async => MusicAuthorizationStatusAuthorized(null));
        when(
          () => musicKit.requestDeveloperToken(),
        ).thenAnswer((_) async => 'devtoken');
        when(() => musicKit.currentCountryCode).thenAnswer((_) async => 'de');

        final built = _build(
          musicKit: musicKit,
          webAuth: _FakeWebAuth(),
          api: api,
          resolver: _FakeResolver(),
          isIOS: true,
        );
        await _settle(built.container);

        await built.session.connect();

        final state = built.container.read(appleMusicSessionProvider);
        expect(state, isA<AppleMusicAuthenticated>());
        final auth = state as AppleMusicAuthenticated;
        expect(auth.developerToken, 'devtoken');
        expect(auth.storefront, 'de');
        expect(auth.musicUserToken, '', reason: 'iOS carries no user token');
        verify(
          () => api.configure(developerToken: 'devtoken', storefront: 'de'),
        ).called(1);
      },
    );

    test('on iOS, a denied prompt stays Unauthenticated, not Error', () async {
      // The user declining the system popup is a choice, not a failure.
      final musicKit = _FakeMusicKit();
      when(
        () => musicKit.authorizationStatus,
      ).thenAnswer((_) async => MusicAuthorizationStatusNotDetermined());
      when(
        () => musicKit.requestAuthorizationStatus(),
      ).thenAnswer((_) async => MusicAuthorizationStatusDenied());

      final built = _build(
        musicKit: musicKit,
        webAuth: _FakeWebAuth(),
        api: _FakeApi(),
        resolver: _FakeResolver(),
        isIOS: true,
      );
      await _settle(built.container);

      await built.session.connect();

      expect(
        built.container.read(appleMusicSessionProvider),
        isA<AppleMusicUnauthenticated>(),
      );
    });

    test('on iOS, a thrown auth flow surfaces an Error state', () async {
      final musicKit = _FakeMusicKit();
      when(
        () => musicKit.authorizationStatus,
      ).thenAnswer((_) async => MusicAuthorizationStatusNotDetermined());
      when(
        () => musicKit.requestAuthorizationStatus(),
      ).thenThrow(Exception('native auth crashed'));

      final built = _build(
        musicKit: musicKit,
        webAuth: _FakeWebAuth(),
        api: _FakeApi(),
        resolver: _FakeResolver(),
        isIOS: true,
      );
      await _settle(built.container);

      await built.session.connect();

      expect(
        built.container.read(appleMusicSessionProvider),
        isA<AppleMusicError>(),
      );
    });
  });

  group('AppleMusicSession.handleCallback', () {
    final callbackUri = Uri.parse(
      'lauschi://apple-music-callback?state=abc&code=tok&storefront=at',
    );

    test(
      'configures both API and stream resolver, then authenticates',
      () async {
        // The unify contract: the callback is the single place that turns web
        // tokens into a playable session, so it must configure the catalog API
        // (dev token) and the stream resolver (dev + user token) together.
        final musicKit = _FakeMusicKit();
        final webAuth = _FakeWebAuth();
        final api = _FakeApi();
        final resolver = _FakeResolver();
        when(() => webAuth.loadStored()).thenAnswer((_) async => null);
        when(() => webAuth.handleCallback(callbackUri)).thenAnswer(
          (_) async =>
              const AppleMusicTokens(musicUserToken: 'tok', storefront: 'at'),
        );

        final built = _build(
          musicKit: musicKit,
          webAuth: webAuth,
          api: api,
          resolver: resolver,
          isIOS: false,
        );
        await _settle(built.container);

        final ok = await built.session.handleCallback(callbackUri);

        expect(ok, isTrue);
        final state = built.container.read(appleMusicSessionProvider);
        expect(state, isA<AppleMusicAuthenticated>());
        final auth = state as AppleMusicAuthenticated;
        expect(auth.developerToken, 'devtoken');
        expect(auth.musicUserToken, 'tok');
        expect(auth.storefront, 'at');
        verify(
          () => api.configure(developerToken: 'devtoken', storefront: 'at'),
        ).called(1);
        verify(
          () => resolver.configure(
            developerToken: 'devtoken',
            musicUserToken: 'tok',
          ),
        ).called(1);
      },
    );

    test(
      'a rejected callback returns false and leaves state untouched',
      () async {
        // No pending login / bad state → webAuth returns null; the session
        // must not authenticate or error, just report failure.
        final musicKit = _FakeMusicKit();
        final webAuth = _FakeWebAuth();
        when(() => webAuth.loadStored()).thenAnswer((_) async => null);
        when(
          () => webAuth.handleCallback(callbackUri),
        ).thenAnswer((_) async => null);

        final built = _build(
          musicKit: musicKit,
          webAuth: webAuth,
          api: _FakeApi(),
          resolver: _FakeResolver(),
          isIOS: false,
        );
        await _settle(built.container);

        final ok = await built.session.handleCallback(callbackUri);

        expect(ok, isFalse);
        expect(
          built.container.read(appleMusicSessionProvider),
          isA<AppleMusicUnauthenticated>(),
        );
      },
    );

    test(
      'a thrown callback surfaces an Error state and returns false',
      () async {
        final musicKit = _FakeMusicKit();
        final webAuth = _FakeWebAuth();
        when(() => webAuth.loadStored()).thenAnswer((_) async => null);
        when(
          () => webAuth.handleCallback(callbackUri),
        ).thenThrow(Exception('callback exploded'));

        final built = _build(
          musicKit: musicKit,
          webAuth: webAuth,
          api: _FakeApi(),
          resolver: _FakeResolver(),
          isIOS: false,
        );
        await _settle(built.container);

        final ok = await built.session.handleCallback(callbackUri);

        expect(ok, isFalse);
        expect(
          built.container.read(appleMusicSessionProvider),
          isA<AppleMusicError>(),
        );
      },
    );
  });

  group('AppleMusicSession.refreshDeveloperToken', () {
    /// An Android session restored from stored web tokens with 'devtoken',
    /// whose developer token answers with [next] from the second call on.
    Future<({ProviderContainer container, AppleMusicSession session})>
    restored({
      required _FakeApi api,
      required _FakeResolver resolver,
      required Future<String> Function() next,
    }) async {
      final musicKit = _FakeMusicKit();
      final webAuth = _FakeWebAuth();
      final developerToken = _FakeDeveloperToken();
      var calls = 0;
      when(
        () => developerToken.current(),
      ).thenAnswer((_) => calls++ == 0 ? Future.value('devtoken') : next());
      when(() => webAuth.loadStored()).thenAnswer(
        (_) async =>
            const AppleMusicTokens(musicUserToken: 'mut', storefront: 'de'),
      );
      when(() => musicKit.setMusicUserToken('mut')).thenAnswer((_) async {});
      final built = _build(
        musicKit: musicKit,
        webAuth: webAuth,
        api: api,
        resolver: resolver,
        isIOS: false,
        developerToken: developerToken,
      );
      await _settle(built.container);
      verifyNever(() => musicKit.requestDeveloperToken());
      return built;
    }

    test('a new token reaches the API, the resolver and the state', () async {
      final api = _FakeApi();
      final resolver = _FakeResolver();
      final built = await restored(
        api: api,
        resolver: resolver,
        next: () async => 'newtoken',
      );

      await built.session.refreshDeveloperToken();

      final auth =
          built.container.read(appleMusicSessionProvider)
              as AppleMusicAuthenticated;
      expect(auth.developerToken, 'newtoken');
      expect(auth.musicUserToken, 'mut');
      expect(auth.storefront, 'de');
      verify(
        () => api.configure(developerToken: 'newtoken', storefront: 'de'),
      ).called(1);
      verify(
        () => resolver.configure(
          developerToken: 'newtoken',
          musicUserToken: 'mut',
        ),
      ).called(1);
    });

    test('the same token leaves the session as it is', () async {
      final built = await restored(
        api: _FakeApi(),
        resolver: _FakeResolver(),
        next: () async => 'devtoken',
      );
      final before = built.container.read(appleMusicSessionProvider);

      await built.session.refreshDeveloperToken();

      expect(built.container.read(appleMusicSessionProvider), same(before));
    });

    test('a failed fetch keeps the current token', () async {
      final built = await restored(
        api: _FakeApi(),
        resolver: _FakeResolver(),
        next: () async => throw Exception('server down'),
      );
      final before = built.container.read(appleMusicSessionProvider);

      await built.session.refreshDeveloperToken();

      expect(built.container.read(appleMusicSessionProvider), same(before));
    });
  });
}
