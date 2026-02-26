import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/parent/widgets/expiry_label.dart';

void main() {
  group('expiryLabel', () {
    test('returns null for permanent content (null availableUntil)', () {
      expect(expiryLabel(null), isNull);
    });

    test('returns null for content expiring in >7 days', () {
      final future = DateTime.now().add(const Duration(days: 30));
      expect(expiryLabel(future), isNull);
    });

    test('returns warning for content expiring in 7 days', () {
      final sevenDays = DateTime.now().add(const Duration(days: 7, hours: 1));
      final result = expiryLabel(sevenDays)!;
      expect(result.text, contains('7'));
      expect(result.text, contains('Tagen'));
      expect(result.color, AppColors.warning);
    });

    test('returns warning for content expiring in 1 day', () {
      final oneDay = DateTime.now().add(const Duration(days: 1, hours: 1));
      final result = expiryLabel(oneDay)!;
      expect(result.text, contains('1'));
      expect(result.text, contains('Tag'));
      // Singular "Tag", not "Tagen".
      expect(result.text, isNot(contains('Tagen')));
      expect(result.color, AppColors.warning);
    });

    test('returns warning with <1 for content expiring today', () {
      final soonToday = DateTime.now().add(const Duration(hours: 3));
      final result = expiryLabel(soonToday)!;
      expect(result.text, contains('<1'));
      expect(result.color, AppColors.warning);
    });

    test('returns error for expired content', () {
      final expired = DateTime.now().subtract(const Duration(hours: 1));
      final result = expiryLabel(expired)!;
      expect(result.text, contains('abgelaufen'));
      expect(result.color, AppColors.error);
    });
  });
}
