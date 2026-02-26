import 'package:flutter/material.dart';
import 'package:lauschi/core/theme/app_theme.dart';

/// Expiry badge for parent-facing item lists.
///
/// Returns null for permanent content or content expiring in >7 days.
({String text, Color color})? expiryLabel(DateTime? availableUntil) {
  if (availableUntil == null) return null;
  final now = DateTime.now();
  if (availableUntil.isBefore(now)) {
    return (text: '⚠ abgelaufen', color: AppColors.error);
  }
  final daysLeft = availableUntil.difference(now).inDays;
  if (daysLeft <= 7) {
    final dayText = daysLeft == 0 ? '<1' : '$daysLeft';
    final unit = daysLeft == 1 ? 'Tag' : 'Tagen';
    return (text: 'läuft in $dayText $unit ab', color: AppColors.warning);
  }
  return null;
}
