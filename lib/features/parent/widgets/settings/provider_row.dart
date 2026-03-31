import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:lauschi/core/apple_music/apple_music_session.dart';
import 'package:lauschi/core/feature_flags.dart';
import 'package:lauschi/core/spotify/spotify_session.dart';
import 'package:lauschi/core/theme/app_theme.dart';

/// Row of provider chips showing connected streaming services.
class ProviderRow extends ConsumerWidget {
  const ProviderRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final spotifyConnected =
        FeatureFlags.enableSpotify &&
        ref.watch(spotifySessionProvider) is SpotifyAuthenticated;
    final appleMusicConnected =
        FeatureFlags.enableAppleMusic &&
        ref.watch(appleMusicSessionProvider) is AppleMusicAuthenticated;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenH),
      child: Row(
        children: [
          if (FeatureFlags.enableSpotify) ...[
            Expanded(
              child: ProviderChip(
                svgAsset: 'assets/images/icons/spotify.svg',
                label: 'Spotify',
                color: const Color(0xFF1DB954),
                active: spotifyConnected,
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
          ],
          if (FeatureFlags.enableAppleMusic) ...[
            Expanded(
              child: ProviderChip(
                svgAsset: 'assets/images/icons/apple_music.svg',
                label: 'Apple Music',
                color: const Color(0xFFFA243C),
                active: appleMusicConnected,
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
          ],
          const Expanded(
            child: ProviderChip(
              svgAsset: 'assets/images/icons/ard_audiothek.svg',
              label: 'ARD',
              color: Color(0xFF003D7A),
              active: true,
              wideIcon: true,
            ),
          ),
        ],
      ),
    );
  }
}

/// Chip showing a streaming provider with icon, label, and active state.
class ProviderChip extends StatelessWidget {
  const ProviderChip({
    required this.label,
    required this.color,
    super.key,
    this.svgAsset,
    this.active = false,
    this.wideIcon = false,
  });

  final String label;
  final Color color;
  final String? svgAsset;
  final bool active;

  /// When true, the SVG is wider than tall (ARD logo).
  final bool wideIcon;

  @override
  Widget build(BuildContext context) {
    final effectiveColor = active ? color : AppColors.textSecondary;

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm + 2,
      ),
      decoration: BoxDecoration(
        color: effectiveColor.withAlpha(active ? 20 : 10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: effectiveColor.withAlpha(active ? 50 : 25)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (svgAsset != null)
            SvgPicture.asset(
              svgAsset!,
              height: 18,
              width: wideIcon ? null : 18,
              colorFilter: ColorFilter.mode(effectiveColor, BlendMode.srcIn),
            ),
          const SizedBox(width: AppSpacing.xs),
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: 'Nunito',
                fontWeight: FontWeight.w700,
                fontSize: 13,
                color: effectiveColor,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
