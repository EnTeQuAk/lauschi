import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/player/player_error.dart';
import 'package:lauschi/features/player/player_provider.dart';

/// Every screen that listens for player errors (kid home, tile detail,
/// player) reacts to the same state change, so a single error would
/// otherwise stack one dialog per mounted screen.
Future<bool>? _activeDialog;

/// Resets the single-dialog guard, which is module state and would
/// otherwise leak across tests that leave a dialog open.
@visibleForTesting
void resetPlayerErrorDialogGuard() => _activeDialog = null;

/// Shows a kid-friendly error dialog with mascot illustration.
///
/// Call from any screen when `playerState.error` is set. The dialog
/// handles clearing the error and popping navigation as needed. Only
/// one dialog is shown at a time: while one is visible, further calls
/// return the visible dialog's future rather than stacking another.
/// Callers can therefore always chain "after the dialog was dismissed"
/// logic onto the returned future.
///
/// Returns true if the user tapped "retry", false otherwise.
Future<bool> showPlayerErrorDialog(
  BuildContext context, {
  required PlayerError error,
}) {
  return _activeDialog ??= showDialog<bool>(
    context: context,
    barrierDismissible: false,
    barrierColor: Colors.black54,
    builder: (_) => _PlayerErrorDialog(error: error),
  ).then((result) {
    _activeDialog = null;
    return result ?? false;
  });
}

/// Gets its own [WidgetRef] via [ConsumerWidget]: the dialog lives on
/// the root navigator and can outlive the screen that showed it, so a
/// captured caller ref could be disposed by the time the button is
/// tapped.
class _PlayerErrorDialog extends ConsumerWidget {
  const _PlayerErrorDialog({required this.error});

  final PlayerError error;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final category = error.category;

    return Dialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.xl,
          AppSpacing.xl,
          AppSpacing.xl,
          AppSpacing.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Mascot illustration (falls back to emoji)
            Image.asset(
              ErrorCategory.asset,
              width: 140,
              height: 140,
              excludeFromSemantics: true,
            ),
            const SizedBox(height: AppSpacing.lg),

            // Kid-friendly headline
            Text(
              category.headline,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: 'Nunito',
                fontSize: 24,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: AppSpacing.sm),

            // Friendly explanation
            Text(
              category.subtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: 'Nunito',
                fontSize: 15,
                color: AppColors.textSecondary,
                height: 1.4,
              ),
            ),
            const SizedBox(height: AppSpacing.md),

            // Technical error detail for parents (small, red)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: AppSpacing.sm,
              ),
              decoration: BoxDecoration(
                color: AppColors.error.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.info_outline_rounded,
                    size: 14,
                    color: AppColors.error,
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  Expanded(
                    child: Text(
                      error.message,
                      style: const TextStyle(
                        fontFamily: 'Nunito',
                        fontSize: 12,
                        color: AppColors.error,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.xl),

            // Action button
            SizedBox(
              width: double.infinity,
              height: 48,
              child: FilledButton(
                onPressed: () {
                  unawaited(HapticFeedback.lightImpact());
                  // Pop before touching providers: the dialog is not
                  // barrier-dismissible, so if anything below throws,
                  // the dialog must already be closed or the user is
                  // trapped behind a dead button.
                  Navigator.of(context).pop(error.isRetryable);
                  ref.read(playerProvider.notifier).clearError();
                },
                child: Text(
                  category.actionLabel,
                  style: const TextStyle(
                    fontFamily: 'Nunito',
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
