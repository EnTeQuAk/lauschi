import 'dart:async' show Timer, unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lauschi/features/onboarding/screens/onboarding_provider.dart';

/// Full-screen splash overlay that stays visible until the app is ready.
///
/// "Ready" = onboarding provider resolved (SharedPreferences loaded) AND
/// a minimum display time of 600ms has passed.
///
/// Native splash is plain cream — this overlay adds the mascot and
/// fades out smoothly once the app content is fully loaded behind it.
class SplashOverlay extends ConsumerStatefulWidget {
  const SplashOverlay({super.key});

  @override
  ConsumerState<SplashOverlay> createState() => _SplashOverlayState();
}

class _SplashOverlayState extends ConsumerState<SplashOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fade;
  bool _minTimePassed = false;
  bool _removed = false;

  @override
  void initState() {
    super.initState();
    _fade = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _fade.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        setState(() => _removed = true);
      }
    });
    // Minimum display time — avoids a blink-and-gone splash
    // when SharedPreferences resolves instantly.
    Timer(const Duration(milliseconds: 600), () {
      if (!mounted) return;
      _minTimePassed = true;
      _maybeDismiss();
    });
  }

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }

  void _maybeDismiss() {
    if (!_minTimePassed) return;
    // Check if onboarding state has resolved (not null).
    final onboarding = ref.read(onboardingCompleteProvider);
    if (onboarding == null) return;
    // App is ready — fade out.
    unawaited(_fade.forward());
  }

  @override
  Widget build(BuildContext context) {
    if (_removed) return const SizedBox.shrink();

    // Watch onboarding state to trigger dismiss when it resolves.
    final onboarding = ref.watch(onboardingCompleteProvider);
    if (onboarding != null) {
      // Schedule dismiss check after this frame.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _maybeDismiss();
      });
    }

    return IgnorePointer(
      child: FadeTransition(
        opacity: ReverseAnimation(_fade),
        child: Container(
          color: const Color(0xFFF2EDE4),
          alignment: Alignment.center,
          child: Image.asset(
            'assets/images/branding/lauschi-mascot.png',
            width: 120,
            height: 120,
          ),
        ),
      ),
    );
  }
}
