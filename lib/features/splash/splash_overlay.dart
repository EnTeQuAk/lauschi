import 'dart:async' show unawaited;

import 'package:flutter/material.dart';

/// Pixel-identical overlay to the native splash screen.
///
/// Shown on top of the app while it initializes. Once [ready] is true,
/// fades out over 400ms and removes itself from the tree.
/// This eliminates the flicker between the native splash and the
/// first Flutter frame.
class SplashOverlay extends StatefulWidget {
  const SplashOverlay({required this.ready, super.key});

  /// When true, the splash begins fading out.
  final bool ready;

  @override
  State<SplashOverlay> createState() => _SplashOverlayState();
}

class _SplashOverlayState extends State<SplashOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _removed = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        setState(() => _removed = true);
      }
    });
  }

  @override
  void didUpdateWidget(SplashOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.ready && !oldWidget.ready) {
      unawaited(_controller.forward());
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_removed) return const SizedBox.shrink();

    return FadeTransition(
      opacity: ReverseAnimation(_controller),
      child: Container(
        // Must match native splash exactly: cream background + centered mascot.
        color: const Color(0xFFF2EDE4),
        alignment: Alignment.center,
        child: Image.asset(
          'assets/images/branding/lauschi-mascot.png',
          width: 120,
          height: 120,
        ),
      ),
    );
  }
}
