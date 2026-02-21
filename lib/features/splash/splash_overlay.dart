import 'dart:async' show Timer, unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lauschi/features/onboarding/screens/onboarding_provider.dart';

/// Full-screen splash overlay that stays visible until the app is ready.
///
/// "Ready" = onboarding provider resolved (SharedPreferences loaded) AND
/// a minimum display time of 600ms has passed.
///
/// Native splash is plain cream — this overlay adds the mascot + wordmark
/// and fades out smoothly once the app content is fully loaded behind it.
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
    final onboarding = ref.read(onboardingCompleteProvider);
    if (onboarding == null) return;
    unawaited(_fade.forward());
  }

  @override
  Widget build(BuildContext context) {
    if (_removed) return const SizedBox.shrink();

    // Watch onboarding state to trigger dismiss when it resolves.
    final onboarding = ref.watch(onboardingCompleteProvider);
    if (onboarding != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _maybeDismiss();
      });
    }

    return IgnorePointer(
      child: FadeTransition(
        opacity: ReverseAnimation(_fade),
        child: Container(
          color: const Color(0xFFF6F3EE),
          alignment: Alignment.center,
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image(
                image: AssetImage('assets/images/branding/lauschi-mascot.png'),
                width: 120,
                height: 120,
              ),
              SizedBox(height: 16),
              Text(
                'lauschi',
                style: TextStyle(
                  fontFamily: 'Nunito',
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF2D7A54),
                  letterSpacing: -0.5,
                  decoration: TextDecoration.none,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
