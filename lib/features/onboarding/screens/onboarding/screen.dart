import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lauschi/core/feature_flags.dart';
import 'package:lauschi/core/router/app_router.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/onboarding/screens/onboarding/widgets/connect_providers_page.dart';
import 'package:lauschi/features/onboarding/screens/onboarding/widgets/pin_setup_page.dart';
import 'package:lauschi/features/onboarding/screens/onboarding/widgets/welcome_page.dart';
import 'package:lauschi/features/onboarding/screens/onboarding_provider.dart';

/// Onboarding for first launch.
///
/// With streaming providers: Welcome → Connect Providers → Set PIN
/// Without: Welcome → Set PIN
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
    WelcomePage(onNext: _next),
    if (_hasStreamingProviders)
      ConnectProvidersPage(onNext: _next, onSkip: _next),
    PinSetupPage(onComplete: _complete),
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
