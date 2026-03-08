import 'package:flutter/material.dart';
import 'package:lauschi/core/theme/app_theme.dart';

/// Progress dialog shown during batch content import.
///
/// [status] updates the header text (e.g. "Lade...", "Speichere...").
/// [progress] is a (done, total) pair. When total is 0, shows an
/// indeterminate progress bar.
class ImportProgressDialog extends StatelessWidget {
  const ImportProgressDialog({
    required this.status,
    required this.progress,
    super.key,
  });

  final ValueNotifier<String> status;
  final ValueNotifier<(int, int)> progress;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ValueListenableBuilder<String>(
              valueListenable: status,
              builder:
                  (_, text, _) => Text(
                    text,
                    style: const TextStyle(
                      fontFamily: 'Nunito',
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                    ),
                  ),
            ),
            const SizedBox(height: AppSpacing.md),
            ValueListenableBuilder<(int, int)>(
              valueListenable: progress,
              builder: (_, pair, _) {
                final (done, total) = pair;
                if (total == 0) {
                  return const LinearProgressIndicator(
                    minHeight: 6,
                    backgroundColor: AppColors.surfaceDim,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      AppColors.primary,
                    ),
                  );
                }
                return Column(
                  children: [
                    ClipRRect(
                      borderRadius: const BorderRadius.all(AppRadius.pill),
                      child: LinearProgressIndicator(
                        value: done / total,
                        minHeight: 6,
                        backgroundColor: AppColors.surfaceDim,
                        valueColor: const AlwaysStoppedAnimation<Color>(
                          AppColors.primary,
                        ),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    Text(
                      '$done von $total',
                      style: const TextStyle(
                        fontFamily: 'Nunito',
                        fontSize: 13,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
