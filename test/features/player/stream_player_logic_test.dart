import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' as ja;
import 'package:lauschi/features/player/stream_player.dart';

/// Unit tests for the pure retry-classification logic extracted from
/// StreamPlayer's old `for (attempt = 0; ...)` loop.
///
/// The orchestration (creating just_audio players, scheduling timers,
/// surfacing state events) is verified by the on-device ARD integration
/// tests. This file covers only the decision: given an error and an
/// attempt counter, do we surface a content error, retry, or give up?
void main() {
  group('classifyStreamError', () {
    group('content errors do not retry', () {
      test('HTTP 403 → contentUnavailable', () {
        expect(
          classifyStreamError(
            error: ja.PlayerException(403, 'Forbidden', null),
            currentAttempt: 0,
            maxRetries: 2,
          ),
          StreamErrorAction.contentUnavailable,
        );
      });

      test('HTTP 404 → contentUnavailable', () {
        expect(
          classifyStreamError(
            error: ja.PlayerException(404, 'Not Found', null),
            currentAttempt: 0,
            maxRetries: 2,
          ),
          StreamErrorAction.contentUnavailable,
        );
      });

      test('HTTP 410 → contentUnavailable (permanently gone)', () {
        expect(
          classifyStreamError(
            error: ja.PlayerException(410, 'Gone', null),
            currentAttempt: 0,
            maxRetries: 2,
          ),
          StreamErrorAction.contentUnavailable,
        );
      });

      test('content error verdict ignores attempt counter', () {
        // Even with retries available, content errors are surfaced
        // immediately. Retrying a 404 won't make the file appear.
        expect(
          classifyStreamError(
            error: ja.PlayerException(404, 'Not Found', null),
            currentAttempt: 0,
            maxRetries: 99,
          ),
          StreamErrorAction.contentUnavailable,
        );
      });
    });

    group('transient errors retry until exhausted', () {
      test('HTTP 500 with attempts remaining → retry', () {
        expect(
          classifyStreamError(
            error: ja.PlayerException(500, 'Server Error', null),
            currentAttempt: 0,
            maxRetries: 2,
          ),
          StreamErrorAction.retry,
        );
      });

      test('HTTP 503 mid-budget → retry', () {
        expect(
          classifyStreamError(
            error: ja.PlayerException(503, 'Unavailable', null),
            currentAttempt: 1,
            maxRetries: 2,
          ),
          StreamErrorAction.retry,
        );
      });

      test('HTTP 500 at budget exhaustion → giveUp', () {
        expect(
          classifyStreamError(
            error: ja.PlayerException(500, 'Server Error', null),
            currentAttempt: 2,
            maxRetries: 2,
          ),
          StreamErrorAction.giveUp,
        );
      });

      test('HTTP 500 past budget → giveUp', () {
        expect(
          classifyStreamError(
            error: ja.PlayerException(500, 'Server Error', null),
            currentAttempt: 3,
            maxRetries: 2,
          ),
          StreamErrorAction.giveUp,
        );
      });

      test('connection reset (code 0) → retry', () {
        // ExoPlayer surfaces some IO errors with code 0.
        expect(
          classifyStreamError(
            error: ja.PlayerException(0, 'Source error', null),
            currentAttempt: 0,
            maxRetries: 2,
          ),
          StreamErrorAction.retry,
        );
      });
    });

    group('non-PlayerException errors are treated as transient', () {
      test('generic Exception → retry while budget remains', () {
        expect(
          classifyStreamError(
            error: Exception('weird thing happened'),
            currentAttempt: 0,
            maxRetries: 2,
          ),
          StreamErrorAction.retry,
        );
      });

      test('generic Exception at budget exhaustion → giveUp', () {
        expect(
          classifyStreamError(
            error: Exception('still weird'),
            currentAttempt: 2,
            maxRetries: 2,
          ),
          StreamErrorAction.giveUp,
        );
      });
    });

    group('zero retry budget', () {
      test('first transient error gives up immediately when maxRetries=0', () {
        expect(
          classifyStreamError(
            error: ja.PlayerException(500, 'Server Error', null),
            currentAttempt: 0,
            maxRetries: 0,
          ),
          StreamErrorAction.giveUp,
        );
      });

      test(
        'content errors still surface as content errors with maxRetries=0',
        () {
          expect(
            classifyStreamError(
              error: ja.PlayerException(404, 'Not Found', null),
              currentAttempt: 0,
              maxRetries: 0,
            ),
            StreamErrorAction.contentUnavailable,
          );
        },
      );
    });
  });
}
