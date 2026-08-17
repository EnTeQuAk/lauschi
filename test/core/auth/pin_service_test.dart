import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/auth/pin_service.dart';

void main() {
  group('isSessionExpired', () {
    final authAt = DateTime(2026, 1, 1, 12);

    test('a null authenticatedAt counts as expired', () {
      expect(isSessionExpired(authenticatedAt: null, now: authAt), isTrue);
    });

    test('within the 15-minute timeout is not expired', () {
      expect(
        isSessionExpired(
          authenticatedAt: authAt,
          now: authAt.add(const Duration(minutes: 14)),
        ),
        isFalse,
      );
    });

    test('at or past the timeout is expired', () {
      expect(
        isSessionExpired(
          authenticatedAt: authAt,
          now: authAt.add(const Duration(minutes: 15)),
        ),
        isTrue,
      );
      expect(
        isSessionExpired(
          authenticatedAt: authAt,
          now: authAt.add(const Duration(minutes: 20)),
        ),
        isTrue,
      );
    });
  });

  group('session inactivity timer', () {
    test('a refresh (same-location touch) does not extend the session', () {
      fakeAsync((async) {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final auth =
            container.read(parentAuthProvider.notifier)
              ..authenticate()
              ..touch('/parent/tiles'); // genuine navigation
        expect(container.read(parentAuthProvider), isTrue);

        async.elapse(const Duration(minutes: 14));
        auth.touch('/parent/tiles'); // same location: a refresh, ignored
        async.elapse(const Duration(minutes: 2)); // 16 min since the real touch

        expect(
          container.read(parentAuthProvider),
          isFalse,
          reason: 'a background refresh must not keep the session alive',
        );
      });
    });

    test('navigation to a new location resets the timer', () {
      fakeAsync((async) {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final auth =
            container.read(parentAuthProvider.notifier)
              ..authenticate()
              ..touch('/parent/tiles');

        async.elapse(const Duration(minutes: 14));
        auth.touch('/parent/settings'); // different location: real navigation
        async.elapse(const Duration(minutes: 2));

        expect(
          container.read(parentAuthProvider),
          isTrue,
          reason: 'navigation resets the inactivity timer',
        );

        // It still expires once genuinely idle.
        async.elapse(const Duration(minutes: 15));
        expect(container.read(parentAuthProvider), isFalse);
      });
    });
  });
}
