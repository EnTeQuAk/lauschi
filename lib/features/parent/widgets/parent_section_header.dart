import 'package:flutter/material.dart';
import 'package:lauschi/core/theme/app_theme.dart';

/// Uppercase section label used across parent screens
/// (dashboard, settings, etc.).
class ParentSectionHeader extends StatelessWidget {
  const ParentSectionHeader({required this.title, super.key});
  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.screenH,
        AppSpacing.md,
        AppSpacing.screenH,
        AppSpacing.xs,
      ),
      child: Text(
        title.toUpperCase(),
        style: const TextStyle(
          fontFamily: 'Nunito',
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
          color: AppColors.textSecondary,
        ),
      ),
    );
  }
}
