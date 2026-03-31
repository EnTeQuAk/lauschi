import 'package:flutter/material.dart';
import 'package:lauschi/core/theme/app_theme.dart';

/// First onboarding page with mascot and "Los geht's" button.
class WelcomePage extends StatelessWidget {
  const WelcomePage({required this.onNext, super.key});
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.xxl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Image.asset(
              'assets/images/branding/lauschi-mascot.png',
              width: 160,
              height: 160,
              excludeFromSemantics: true,
            ),
            const SizedBox(height: AppSpacing.xl),
            const Text(
              'lauschi',
              style: TextStyle(
                fontFamily: 'Nunito',
                fontSize: 36,
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary,
                letterSpacing: -0.5,
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            const Text(
              'Dein Hörspiel-Player',
              style: TextStyle(
                fontFamily: 'Nunito',
                fontSize: 18,
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: AppSpacing.xxl),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                key: const Key('onboarding_start'),
                onPressed: onNext,
                child: const Text("Los geht's"),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
