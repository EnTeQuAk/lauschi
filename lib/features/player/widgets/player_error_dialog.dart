import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/player/player_error.dart';
import 'package:lauschi/features/player/player_provider.dart';

/// Shows a kid-friendly error dialog with mascot illustration.
///
/// Call from any screen when `playerState.error` is set. The dialog
/// handles clearing the error and popping navigation as needed.
///
/// Returns true if the user tapped "retry", false otherwise.
Future<bool> showPlayerErrorDialog(
  BuildContext context, {
  required WidgetRef ref,
  required PlayerError error,
}) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    barrierColor: Colors.black54,
    builder: (_) => _PlayerErrorDialog(ref: ref, error: error),
  );
  return result ?? false;
}

class _PlayerErrorDialog extends StatelessWidget {
  const _PlayerErrorDialog({required this.ref, required this.error});

  final WidgetRef ref;
  final PlayerError error;

  @override
  Widget build(BuildContext context) {
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
            _MascotImage(
              asset: ErrorCategory.asset,
              fallbackEmoji: ErrorCategory.fallbackEmoji,
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
                  ref.read(playerProvider.notifier).clearError();
                  Navigator.of(context).pop(error.isRetryable);
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

/// Shows the mascot PNG if it exists, otherwise falls back to a large emoji.
///
/// Uses `Image.asset` with an `errorBuilder` so missing PNGs (mascots
/// not yet illustrated) degrade gracefully without crashing.
class _MascotImage extends StatelessWidget {
  const _MascotImage({required this.asset, required this.fallbackEmoji});

  final String asset;
  final String fallbackEmoji;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 140,
      height: 140,
      child: Image.asset(
        asset,
        width: 140,
        height: 140,
        errorBuilder:
            (_, error, stack) => Center(
              child: Text(
                fallbackEmoji,
                style: const TextStyle(fontSize: 64),
              ),
            ),
      ),
    );
  }
}
