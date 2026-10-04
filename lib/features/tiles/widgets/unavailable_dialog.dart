import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:lauschi/core/theme/app_theme.dart';

/// Explains to a kid why a greyed-out card doesn't play.
void showUnavailableDialog(BuildContext context) {
  unawaited(
    showDialog<void>(
      context: context,
      builder:
          (_) => Dialog(
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
                  Image.asset(
                    'assets/images/branding/lauschi-confused.png',
                    width: 80,
                    height: 80,
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  const Text(
                    'Gerade nicht verfügbar',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: 'Nunito',
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  const Text(
                    'Diese Folge ist gerade nicht abrufbar. '
                    'Manchmal werden Inhalte später wieder '
                    'freigeschaltet.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: 'Nunito',
                      fontSize: 15,
                      color: AppColors.textSecondary,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xl),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: FilledButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text(
                        'Verstanden',
                        style: TextStyle(
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
          ),
    ),
  );
}
