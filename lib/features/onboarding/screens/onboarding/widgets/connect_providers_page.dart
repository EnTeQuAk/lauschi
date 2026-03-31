import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:lauschi/core/apple_music/apple_music_session.dart';
import 'package:lauschi/core/feature_flags.dart';
import 'package:lauschi/core/providers/provider_type.dart';
import 'package:lauschi/core/spotify/spotify_session.dart';
import 'package:lauschi/core/theme/app_theme.dart';

/// Onboarding page showing all available content providers.
///
/// ARD Audiothek is highlighted as always-free. Streaming providers
/// (Spotify, Apple Music) appear based on feature flags with connect
/// buttons.
class ConnectProvidersPage extends ConsumerWidget {
  const ConnectProvidersPage({
    required this.onNext,
    required this.onSkip,
    super.key,
  });

  final VoidCallback onNext;
  final VoidCallback onSkip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return LayoutBuilder(
      builder:
          (context, constraints) => SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xxl),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Image.asset(
                    'assets/images/branding/lauschi-discover.png',
                    width: 140,
                    height: 140,
                    excludeFromSemantics: true,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  const Text(
                    'Inhalte entdecken',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: 'Nunito',
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  const Text(
                    'Kostenlose Hörspiele der ARD Audiothek sind '
                    'immer verfügbar. Mit einem Streaming-Abo '
                    'kannst du noch mehr entdecken.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: 'Nunito',
                      fontSize: 14,
                      height: 1.4,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  const _ProviderCard(
                    type: ProviderType.ardAudiothek,
                    svgAsset: 'assets/images/icons/ard_audiothek.svg',
                    label: 'ARD Audiothek',
                    subtitle: 'Kostenlos, ohne Abo',
                    connected: true,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  if (FeatureFlags.enableAppleMusic) ...[
                    const _AppleMusicCard(),
                    const SizedBox(height: AppSpacing.sm),
                  ],
                  if (FeatureFlags.enableSpotify) ...[
                    const _SpotifyCard(),
                    const SizedBox(height: AppSpacing.sm),
                  ],
                  const SizedBox(height: AppSpacing.md),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      key: const Key('onboarding_providers_next'),
                      onPressed: onNext,
                      child: const Text('Weiter'),
                    ),
                  ),
                ],
              ),
            ),
          ),
    );
  }
}

// ── Provider-specific cards (inline, only used here) ────────────────────────

class _SpotifyCard extends ConsumerWidget {
  const _SpotifyCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(spotifySessionProvider);
    final connected = state is SpotifyAuthenticated;
    final loading = state is SpotifyLoading;

    return _ProviderCard(
      key: const Key('spotify_connect'),
      type: ProviderType.spotify,
      svgAsset: 'assets/images/icons/spotify.svg',
      label: 'Spotify',
      subtitle:
          loading
              ? 'Verbinde…'
              : connected
              ? 'Verbunden'
              : 'Premium Abo nötig',
      connected: connected,
      loading: loading,
      onConnect:
          connected || loading
              ? null
              : () async {
                final session = ref.read(spotifySessionProvider.notifier);
                await session.login();
              },
    );
  }
}

class _AppleMusicCard extends ConsumerWidget {
  const _AppleMusicCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(appleMusicSessionProvider);
    final connected = state is AppleMusicAuthenticated;
    final loading = state is AppleMusicLoading;

    return _ProviderCard(
      key: const Key('apple_music_connect'),
      type: ProviderType.appleMusic,
      svgAsset: 'assets/images/icons/apple_music.svg',
      label: 'Apple Music',
      subtitle:
          loading
              ? 'Verbinde…'
              : connected
              ? 'Verbunden'
              : 'Abo nötig',
      connected: connected,
      loading: loading,
      onConnect:
          connected || loading
              ? null
              : () async {
                await ref.read(appleMusicSessionProvider.notifier).connect();
              },
    );
  }
}

/// Card representing a content provider with logo, name, and status.
class _ProviderCard extends StatelessWidget {
  const _ProviderCard({
    required this.type,
    required this.svgAsset,
    required this.label,
    required this.subtitle,
    required this.connected,
    this.loading = false,
    this.onConnect,
    super.key,
  });

  final ProviderType type;
  final String svgAsset;
  final String label;
  final String subtitle;
  final bool connected;
  final bool loading;
  final VoidCallback? onConnect;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: 12,
      ),
      decoration: BoxDecoration(
        color: connected ? type.color.withAlpha(15) : AppColors.parentSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: connected ? type.color.withAlpha(60) : AppColors.surfaceDim,
        ),
      ),
      child: Row(
        children: [
          SvgPicture.asset(
            svgAsset,
            height: 24,
            width: type == ProviderType.ardAudiothek ? null : 24,
            colorFilter:
                type == ProviderType.ardAudiothek
                    ? ColorFilter.mode(type.color, BlendMode.srcIn)
                    : null,
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    fontFamily: 'Nunito',
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                  ),
                ),
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontFamily: 'Nunito',
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          if (loading)
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: type.color,
              ),
            )
          else if (connected)
            Icon(Icons.check_circle_rounded, color: type.color, size: 22)
          else if (onConnect != null)
            TextButton(
              onPressed: onConnect,
              style: TextButton.styleFrom(
                foregroundColor: AppColors.textSecondary,
                textStyle: const TextStyle(
                  fontFamily: 'Nunito',
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
              child: const Text('Verbinden'),
            ),
        ],
      ),
    );
  }
}
