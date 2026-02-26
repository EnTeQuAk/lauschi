import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/parent/widgets/expiry_label.dart';

void main() {
  final now = DateTime(2025, 6, 15, 12);

  group('expiryLabel', () {
    test('returns null for permanent content (null availableUntil)', () {
      expect(expiryLabel(null, now: now), isNull);
    });

    test('returns null for content expiring in >7 days', () {
      expect(expiryLabel(DateTime(2025, 7, 15), now: now), isNull);
    });

    test('returns warning for content expiring in 7 days', () {
      final result = expiryLabel(DateTime(2025, 6, 22, 13), now: now)!;
      expect(result.text, contains('7'));
      expect(result.text, contains('Tagen'));
      expect(result.color, AppColors.warning);
    });

    test('returns warning for content expiring in 1 day', () {
      final result = expiryLabel(DateTime(2025, 6, 16, 13), now: now)!;
      expect(result.text, contains('1'));
      expect(result.text, contains('Tag'));
      // Singular "Tag", not "Tagen".
      expect(result.text, isNot(contains('Tagen')));
      expect(result.color, AppColors.warning);
    });

    test('returns warning with <1 for content expiring today', () {
      final result = expiryLabel(DateTime(2025, 6, 15, 15), now: now)!;
      expect(result.text, contains('<1'));
      expect(result.color, AppColors.warning);
    });

    test('returns error for expired content', () {
      final result = expiryLabel(DateTime(2025, 6, 15, 11), now: now)!;
      expect(result.text, contains('abgelaufen'));
      expect(result.color, AppColors.error);
    });
  });
}
