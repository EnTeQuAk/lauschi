import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:lauschi/core/feature_flags.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:url_launcher/url_launcher.dart';

/// Builds the disclaimer sentence shown above the ardaudiothek.de link.
///
/// Pure function so we can unit-test all four combinations of feature
/// flags without re-compiling with different `--dart-define` values.
/// The trailing space before the link is intentional.
String buildProviderAttributionSentence({
  required bool spotifyEnabled,
  required bool appleMusicEnabled,
}) {
  final providers = <String>['ARD Audiothek'];
  if (spotifyEnabled) providers.add('Spotify');
  if (appleMusicEnabled) providers.add('Apple Music');

  if (providers.length == 1) {
    return 'Audioinhalte stammen von der ${providers.first}. '
        'lauschi ist kein offizielles Angebot der ARD. Mehr Hörspiele auf ';
  }

  // Join with comma and "und" before the last item: a, b und c.
  final last = providers.removeLast();
  final joined = '${providers.join(', ')} und $last';
  return 'Audioinhalte stammen von $joined. '
      'lauschi ist kein offizielles Angebot dieser Anbieter. '
      'Mehr Hörspiele auf ';
}

/// Attribution notice for the audio content sources.
///
/// Lists the providers actually compiled into the build (ARD always,
/// Spotify and Apple Music behind their feature flags) and disclaims
/// any official affiliation with them. The branded display of each
/// provider lives in `ProviderRow` above this widget: the chips with
/// SVG logos satisfy Spotify's and Apple Music's "display the brand
/// prominently" requirements, and this paragraph is the disclaimer.
///
/// The ardaudiothek.de link is kept because ARD is the only provider
/// where the user can discover and play content for free without an
/// existing account; Spotify and Apple Music are accessed through their
/// own apps and accounts.
class ProviderAttribution extends StatelessWidget {
  const ProviderAttribution({super.key});

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
            TextSpan(
              text: buildProviderAttributionSentence(
                spotifyEnabled: FeatureFlags.enableSpotify,
                appleMusicEnabled: FeatureFlags.enableAppleMusic,
              ),
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
            const TextSpan(text: '.'),
          ],
        ),
      ),
    );
  }
}
