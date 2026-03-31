import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:url_launcher/url_launcher.dart';

/// Attribution notice for ARD Audiothek content.
class ArdAttribution extends StatelessWidget {
  const ArdAttribution({super.key});

  static final _ardUrl = Uri.parse('https://www.ardaudiothek.de');

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.screenH,
        AppSpacing.sm,
        AppSpacing.screenH,
        0,
      ),
      child: Text.rich(
        TextSpan(
          style: const TextStyle(
            fontFamily: 'Nunito',
            fontSize: 12,
            height: 1.4,
            color: AppColors.textSecondary,
          ),
          children: [
            const TextSpan(
              text:
                  'Audioinhalte werden von der ARD Audiothek '
                  'bereitgestellt. lauschi ist kein offizielles '
                  'Angebot der ARD. ',
            ),
            WidgetSpan(
              alignment: PlaceholderAlignment.baseline,
              baseline: TextBaseline.alphabetic,
              child: GestureDetector(
                onTap:
                    () => unawaited(
                      launchUrl(
                        _ardUrl,
                        mode: LaunchMode.externalApplication,
                      ),
                    ),
                child: const Text(
                  'ardaudiothek.de',
                  style: TextStyle(
                    fontFamily: 'Nunito',
                    fontSize: 12,
                    color: AppColors.primary,
                    decoration: TextDecoration.underline,
                    decorationColor: AppColors.primary,
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
