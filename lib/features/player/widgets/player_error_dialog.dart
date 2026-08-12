import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lauschi/core/router/app_router.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/player/player_error.dart';
import 'package:lauschi/features/player/player_provider.dart';

/// Owns the player error dialog. Mounted once above the router
/// (app.dart's MaterialApp builder), so player errors surface no
/// matter which screen is open, and exactly one dialog exists at a
/// time — the dialog re-renders in place when a different error
/// arrives while it is open.
///
/// Dismissing the dialog clears the error. Leaving the dead player
/// screen when its content fails is the player screen's own concern
/// (it pops itself once the error clears).
class PlayerErrorHost extends ConsumerStatefulWidget {
  const PlayerErrorHost({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<PlayerErrorHost> createState() => _PlayerErrorHostState();
}

class _PlayerErrorHostState extends ConsumerState<PlayerErrorHost> {
  bool _dialogOpen = false;

  void _showDialogFor(PlayerError error) {
    final navContext = ref.read(rootNavigatorKeyProvider).currentContext;
    if (navContext == null) return; // router not mounted yet
    _dialogOpen = true;
    unawaited(
      showDialog<bool>(
        context: navContext,
        barrierDismissible: false,
        barrierColor: Colors.black54,
        builder: (_) => _PlayerErrorDialog(initialError: error),
      ).whenComplete(() => _dialogOpen = false),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(playerProvider.select((s) => s.error), (prev, next) {
      if (next == null || next == prev || _dialogOpen) return;
      // Post-frame: the error can be set during a build/navigation.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _dialogOpen) return;
        // Re-read: the error may already be gone by the time the
        // frame ends (cleared by a successful retry elsewhere).
        final error = ref.read(playerProvider).error;
        if (error == null) return;
        _showDialogFor(error);
      });
    });
    return widget.child;
  }
}

/// Gets its own [WidgetRef] via [ConsumerWidget]: the dialog lives on
/// the root navigator and can outlive the screen that showed it, so a
/// captured caller ref could be disposed by the time the button is
/// tapped.
class _PlayerErrorDialog extends ConsumerWidget {
  const _PlayerErrorDialog({required this.initialError});

  /// The error the dialog opened with; only a fallback for the moment
  /// between clearError and the pop completing.
  final PlayerError initialError;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Render the live error: only one dialog shows at a time, so when
    // a different error arrives while this one is open it takes over
    // the visible dialog instead of being dropped unseen. The
    // constructor error covers the moment between clearError and the
    // pop completing, when state briefly holds null.
    final current =
        ref.watch(playerProvider.select((s) => s.error)) ?? initialError;

    // The action button pops with a result and clears the error itself.
    // A system back pop delivers no result; the error must still be
    // cleared or the stale state suppresses the dialog for the next
    // identical error.
    return PopScope(
      onPopInvokedWithResult: (didPop, result) {
        if (didPop && result == null) {
          ref.read(playerProvider.notifier).clearError();
        }
      },
      child: _buildDialog(context, ref, current),
    );
  }

  Widget _buildDialog(
    BuildContext context,
    WidgetRef ref,
    PlayerError error,
  ) {
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
