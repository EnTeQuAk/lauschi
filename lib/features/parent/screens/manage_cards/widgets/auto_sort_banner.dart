import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lauschi/core/theme/app_theme.dart';

/// Banner prompting auto-sort of ungrouped cards into series.
class AutoSortBanner extends ConsumerWidget {
  const AutoSortBanner({
    required this.ungroupedCount,
    required this.onSort,
    super.key,
    this.onTap,
  });

  final int ungroupedCount;

  /// Called when the "Einordnen" button is pressed.
  final VoidCallback onSort;

  /// Called when the banner body is tapped (scroll to ungrouped section).
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(
          horizontal: AppSpacing.screenH,
          vertical: AppSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: AppColors.primary.withValues(alpha: 0.08),
          borderRadius: const BorderRadius.all(AppRadius.card),
        ),
        child: ListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.xs,
          ),
          leading: const Icon(
            Icons.auto_awesome_rounded,
            color: AppColors.primary,
            size: 20,
          ),
          title: Text(
            ungroupedCount == 1
                ? '1 Karte ohne Serie'
                : '$ungroupedCount Karten ohne Serie',
            style: const TextStyle(
              fontFamily: 'Nunito',
              fontWeight: FontWeight.w700,
              fontSize: 14,
              color: AppColors.primary,
            ),
          ),
          trailing: FilledButton(
            onPressed: onSort,
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: AppSpacing.xs,
              ),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('Einordnen'),
          ),
        ),
      ),
    );
  }
}
