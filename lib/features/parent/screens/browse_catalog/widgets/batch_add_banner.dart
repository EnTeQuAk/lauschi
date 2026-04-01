import 'package:flutter/material.dart';
import 'package:lauschi/core/theme/app_theme.dart';

/// Banner prompting the parent to batch-add all matched albums
/// for a catalog series.
class BatchAddBanner extends StatelessWidget {
  const BatchAddBanner({
    required this.seriesTitle,
    required this.count,
    required this.onAddAll,
    super.key,
  });

  final String seriesTitle;
  final int count;
  final VoidCallback onAddAll;

  @override
  Widget build(BuildContext context) {
    if (count == 0) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.symmetric(
        horizontal: AppSpacing.screenH,
        vertical: AppSpacing.xs,
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
          Icons.layers_rounded,
          color: AppColors.primary,
          size: 20,
        ),
        title: Text(
          count == 1
              ? 'Zur Kachel »$seriesTitle« hinzufügen'
              : 'Alle $count Einträge zu »$seriesTitle« hinzufügen',
          style: const TextStyle(
            fontFamily: 'Nunito',
            fontWeight: FontWeight.w700,
            fontSize: 14,
            color: AppColors.primary,
          ),
        ),
        trailing: FilledButton(
          onPressed: onAddAll,
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.xs,
            ),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: Text(count == 1 ? 'Hinzufügen' : 'Alle hinzufügen'),
        ),
      ),
    );
  }
}
