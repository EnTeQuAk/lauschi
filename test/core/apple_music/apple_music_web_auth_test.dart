import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/apple_music/apple_music_web_auth.dart';
import 'package:mocktail/mocktail.dart';

class _MockStorage extends Mock implements FlutterSecureStorage {}

const _pendingStateKey = 'apple_music_pending_state';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _MockStorage storage;
  late AppleMusicWebAuth auth;

  setUp(() {
    storage = _MockStorage();
    auth = AppleMusicWebAuth(storage: storage);
    when(
      () => storage.write(key: any(named: 'key'), value: any(named: 'value')),
    ).thenAnswer((_) async {});
    when(
      () => storage.delete(key: any(named: 'key')),
    ).thenAnswer((_) async {});
    when(
      () => storage.read(key: any(named: 'key')),
    ).thenAnswer((_) async => null);
  });

  test('a failed browser open leaves no replayable CSRF state', () async {
    // launchUrl has no platform binding in a unit test, so every mode
    // fails and login() hits its !launched branch. That branch must not
    // orphan the pending-state (in-memory and in the keychain), or a
    // later replayed callback carrying that state would pass the CSRF
    // check.
    await expectLater(
      () => auth.login(developerToken: 'dev-token'),
      throwsA(isA<StateError>()),
    );

    // The state login() generated and persisted...
    final captured =
        verify(
              () => storage.write(
                key: _pendingStateKey,
                value: captureAny(named: 'value'),
              ),
            ).captured.single
            as String;

    // ...must be deleted from the keychain on the failure path.
    verify(() => storage.delete(key: _pendingStateKey)).called(1);

    // ...and the in-memory state cleared, so a callback replaying that
    // exact state is rejected as "no login pending", not accepted.
    final result = await auth.handleCallback(
      Uri.parse('lauschi://apple-music-callback?state=$captured&code=tok123'),
    );
    expect(result, isNull);
  });
}
