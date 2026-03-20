import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';
import 'package:lauschi/core/apple_music/apple_music_session.dart';
import 'package:lauschi/core/auth/pin_service.dart';
import 'package:lauschi/core/auth/pin_widgets.dart';
import 'package:lauschi/core/feature_flags.dart';
import 'package:lauschi/core/providers/provider_type.dart';
import 'package:lauschi/core/router/app_router.dart';
import 'package:lauschi/core/spotify/spotify_session.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/onboarding/screens/onboarding_provider.dart';

/// Onboarding for first launch.
///
/// With Spotify: Welcome → Connect Spotify → Set PIN
/// Without Spotify: Welcome → Set PIN
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final _pageController = PageController();
  int _currentPage = 0;

  static const _hasStreamingProviders =
      FeatureFlags.enableSpotify || FeatureFlags.enableAppleMusic;

  List<Widget> get _pages => [
    _WelcomePage(onNext: _next),
    if (_hasStreamingProviders)
      _ConnectProvidersPage(onNext: _next, onSkip: _next),
    _PinSetupPage(onComplete: _complete),
  ];

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _next() {
    if (_currentPage < _pages.length - 1) {
      unawaited(
        _pageController.nextPage(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
        ),
      );
    }
  }

  Future<void> _complete() async {
    await ref.read(onboardingCompleteProvider.notifier).markComplete();
    if (mounted) {
      // Kid home's empty state has a clear "Hörspiel hinzufügen" CTA —
      // no need to dump parents into settings behind another PIN prompt.
      context.go(AppRoutes.kidHome);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pages = _pages;
    final pageCount = pages.length;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: PageView(
                controller: _pageController,
                onPageChanged: (page) => setState(() => _currentPage = page),
                physics: const NeverScrollableScrollPhysics(),
                children: pages,
              ),
            ),
            // Page indicators
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.xl),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(pageCount, (index) {
                  return Semantics(
                    label: 'Seite ${index + 1} von $pageCount',
                    selected: index == _currentPage,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                      width: index == _currentPage ? 24 : 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color:
                            index == _currentPage
                                ? AppColors.primary
                                : AppColors.surfaceDim,
                        borderRadius: const BorderRadius.all(AppRadius.pill),
                      ),
                    ),
                  );
                }),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WelcomePage extends StatelessWidget {
  const _WelcomePage({required this.onNext});
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    return Padding(
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
    );
  }
}

/// Onboarding page showing all available content providers.
///
/// ARD Audiothek is highlighted as always-free. Streaming providers
/// (Spotify, Apple Music) appear based on feature flags with connect
/// buttons.
class _ConnectProvidersPage extends ConsumerWidget {
  const _ConnectProvidersPage({required this.onNext, required this.onSkip});
  final VoidCallback onNext;
  final VoidCallback onSkip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.xxl),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.headphones_rounded,
            size: 64,
            color: AppColors.primary,
          ),
          const SizedBox(height: AppSpacing.xl),
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
          const SizedBox(height: AppSpacing.md),
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
          const SizedBox(height: AppSpacing.xl),

          // ARD Audiothek -- always available, highlighted
          const _ProviderCard(
            type: ProviderType.ardAudiothek,
            svgAsset: 'assets/images/icons/ard_audiothek.svg',
            label: 'ARD Audiothek',
            subtitle: 'Kostenlos, ohne Abo',
            connected: true,
          ),
          const SizedBox(height: AppSpacing.sm),

          if (FeatureFlags.enableAppleMusic) ...[
            _AppleMusicCard(ref: ref),
            const SizedBox(height: AppSpacing.sm),
          ],

          if (FeatureFlags.enableSpotify) ...[
            _SpotifyCard(ref: ref),
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
    );
  }
}

class _SpotifyCard extends StatelessWidget {
  const _SpotifyCard({required this.ref});
  final WidgetRef ref;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(spotifySessionProvider);
    final connected = state is SpotifyAuthenticated;

    return _ProviderCard(
      key: const Key('spotify_connect'),
      type: ProviderType.spotify,
      svgAsset: 'assets/images/icons/spotify.svg',
      label: 'Spotify',
      subtitle: connected ? 'Verbunden' : 'Premium Abo nötig',
      connected: connected,
      onConnect:
          connected
              ? null
              : () async {
                final session = ref.read(spotifySessionProvider.notifier);
                await session.login();
              },
    );
  }
}

class _AppleMusicCard extends StatelessWidget {
  const _AppleMusicCard({required this.ref});
  final WidgetRef ref;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(appleMusicSessionProvider);
    final connected = state is AppleMusicAuthenticated;

    return _ProviderCard(
      key: const Key('apple_music_connect'),
      type: ProviderType.appleMusic,
      svgAsset: 'assets/images/icons/apple_music.svg',
      label: 'Apple Music',
      subtitle: connected ? 'Verbunden' : 'Abo nötig',
      connected: connected,
      onConnect:
          connected
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
    this.onConnect,
    super.key,
  });

  final ProviderType type;
  final String svgAsset;
  final String label;
  final String subtitle;
  final bool connected;
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
          if (connected)
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

class _PinSetupPage extends ConsumerStatefulWidget {
  const _PinSetupPage({required this.onComplete});
  final VoidCallback onComplete;

  @override
  ConsumerState<_PinSetupPage> createState() => _PinSetupPageState();
}

class _PinSetupPageState extends ConsumerState<_PinSetupPage> {
  final _pin = <int>[];
  String? _firstPin;
  bool _error = false;

  bool get _isConfirming => _firstPin != null;
  static const _pinLength = 4;

  Future<void> _onDigit(int digit) async {
    if (_pin.length >= _pinLength) return;

    setState(() {
      _pin.add(digit);
      _error = false;
    });

    if (_pin.length < _pinLength) return;

    final pinStr = _pin.map((d) => d.toString()).join();

    if (_firstPin == null) {
      setState(() {
        _firstPin = pinStr;
        _pin.clear();
      });
    } else if (_firstPin == pinStr) {
      final pinService = ref.read(pinServiceProvider);
      await pinService.setPin(pinStr);
      widget.onComplete();
    } else {
      setState(() {
        _firstPin = null;
        _pin.clear();
        _error = true;
      });
    }
  }

  void _onBackspace() {
    if (_pin.isEmpty) return;
    setState(() {
      _pin.removeLast();
      _error = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.lock_open_rounded,
            size: 48,
            color: AppColors.primary,
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            _isConfirming ? 'PIN bestätigen' : 'Eltern-PIN festlegen',
            style: const TextStyle(
              fontFamily: 'Nunito',
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            _isConfirming ? 'Nochmal eingeben' : 'Wähle eine 4-stellige PIN',
            style: const TextStyle(
              fontFamily: 'Nunito',
              fontSize: 15,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: AppSpacing.xl),
          PinDots(
            length: _pinLength,
            filled: _pin.length,
            hasError: _error,
          ),
          if (_error) ...[
            const SizedBox(height: AppSpacing.sm),
            const Text(
              'PINs stimmen nicht überein',
              style: TextStyle(
                fontFamily: 'Nunito',
                fontSize: 13,
                color: AppColors.error,
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.xl),
          PinNumpad(
            onDigit: _onDigit,
            onBackspace: _onBackspace,
          ),
        ],
      ),
    );
  }
}
