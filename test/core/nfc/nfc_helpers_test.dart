import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/nfc/nfc_listener.dart';
import 'package:lauschi/core/nfc/nfc_service.dart';

void main() {
  group('redactUid', () {
    test('shows only the first 4 chars of a long UID', () {
      expect(redactUid('ab:cd:ef:12'), 'ab:c...');
    });

    test('returns a short UID unchanged', () {
      expect(redactUid('ab'), 'ab');
    });
  });

  group('isDuplicateScan', () {
    test('the same tag within the window is a duplicate', () {
      expect(
        isDuplicateScan(
          uid: 'a',
          lastUid: 'a',
          sinceLast: const Duration(seconds: 1),
        ),
        isTrue,
      );
    });

    test('the same tag after the window is not', () {
      expect(
        isDuplicateScan(
          uid: 'a',
          lastUid: 'a',
          sinceLast: const Duration(seconds: 5),
        ),
        isFalse,
      );
    });

    test('a different tag is never a duplicate', () {
      expect(
        isDuplicateScan(
          uid: 'b',
          lastUid: 'a',
          sinceLast: const Duration(seconds: 1),
        ),
        isFalse,
      );
    });

    test('the first scan (no previous) is not a duplicate', () {
      expect(
        isDuplicateScan(uid: 'a', lastUid: null, sinceLast: null),
        isFalse,
      );
    });
  });
}
