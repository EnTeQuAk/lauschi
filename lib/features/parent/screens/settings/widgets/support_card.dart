import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:url_launcher/url_launcher.dart';

/// "lauschi ist ein Herzensprojekt" support card with donation and GitHub links.
class SupportCard extends StatelessWidget {
  const SupportCard({super.key});

  static final _buyMeACoffee = Uri.parse('https://buymeacoffee.com/cgrebs');
  static final _gitHub = Uri.parse('https://github.com/EnTeQuAk/lauschi');

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenH),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.primaryPale,
          borderRadius: BorderRadius.circular(16),
        ),
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          children: [
            const Icon(
              Icons.favorite_rounded,
              color: AppColors.primary,
              size: 28,
            ),
            const SizedBox(height: AppSpacing.sm),
            const Text(
              'lauschi ist ein Herzensprojekt',
              style: TextStyle(
                fontFamily: 'Nunito',
                fontWeight: FontWeight.w800,
                fontSize: 17,
                color: AppColors.primary,
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            const Text(
              'Kostenlos, werbefrei und ohne Abo. '
              'Wenn dir lauschi gefällt, kannst du '
              'die Entwicklung unterstützen.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'Nunito',
                fontSize: 13,
                height: 1.4,
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                key: const Key('buy_coffee_button'),
                onPressed: () => _open(_buyMeACoffee),
                icon: const Icon(Icons.coffee_rounded, size: 18),
                label: const Text(
                  'Kaffee spendieren',
                  style: TextStyle(fontFamily: 'Nunito', fontSize: 14),
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: AppColors.textOnPrimary,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                key: const Key('github_button'),
                onPressed: () => _open(_gitHub),
                icon: SvgPicture.asset(
                  'assets/images/icons/github.svg',
                  width: 18,
                  height: 18,
                  colorFilter: const ColorFilter.mode(
                    AppColors.primary,
                    BlendMode.srcIn,
                  ),
                ),
                label: const Text(
                  'GitHub',
                  style: TextStyle(fontFamily: 'Nunito', fontSize: 14),
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.primary,
                  side: const BorderSide(color: AppColors.primary),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _open(Uri url) {
    unawaited(launchUrl(url, mode: LaunchMode.externalApplication));
  }
}
