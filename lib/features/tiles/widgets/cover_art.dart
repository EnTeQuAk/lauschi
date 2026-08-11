import 'dart:async' show unawaited;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:lauschi/core/theme/app_theme.dart';

/// Cover artwork with the shared loading and failure policy: shimmer
/// while loading, [fallback] for missing urls and failed loads (stored
/// CDN urls rotate and start 404ing long after a card was added).
class CoverImage extends StatelessWidget {
  const CoverImage({
    required this.url,
    super.key,
    this.fallback = const CoverFallback(),
    this.memCacheWidth = 400,
  });

  final String? url;
  final Widget fallback;

  /// Decode size cap: 2x display size keeps grid images sharp on
  /// high-DPI without wasting memory on full-resolution CDN images.
  /// See #226.
  final int memCacheWidth;

  @override
  Widget build(BuildContext context) {
    final url = this.url;
    if (url == null || url.isEmpty) return fallback;

    return CachedNetworkImage(
      imageUrl: url,
      fit: BoxFit.cover,
      memCacheWidth: memCacheWidth,
      placeholder: (_, _) => const ShimmerPlaceholder(),
      errorWidget: (_, _, _) => fallback,
    );
  }
}

/// Neutral cover stand-in: dim surface with an icon.
class CoverFallback extends StatelessWidget {
  const CoverFallback({super.key, this.icon = Icons.music_note_rounded});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppColors.surfaceDim,
      child: Icon(icon, size: 48, color: AppColors.textSecondary),
    );
  }
}

/// Greyscale plus surface scrim over [child]: the shared treatment for
/// content that cannot play right now (expired episode cards, tiles
/// whose episodes are all unavailable).
class UnavailableWash extends StatelessWidget {
  const UnavailableWash({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.passthrough,
      children: [
        ColorFiltered(colorFilter: greyscaleFilter, child: child),
        Positioned.fill(
          child: ColoredBox(color: AppColors.surface.withValues(alpha: 0.6)),
        ),
      ],
    );
  }
}

/// Animated loading placeholder for cover slots.
class ShimmerPlaceholder extends StatefulWidget {
  const ShimmerPlaceholder({super.key});

  @override
  State<ShimmerPlaceholder> createState() => _ShimmerPlaceholderState();
}

class _ShimmerPlaceholderState extends State<ShimmerPlaceholder>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    );
    unawaited(_controller.repeat());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment(-1.0 + 2.0 * _controller.value, 0),
              end: Alignment(1.0 + 2.0 * _controller.value, 0),
              colors: const [
                AppColors.surfaceDim,
                AppColors.surface,
                AppColors.surfaceDim,
              ],
            ),
          ),
        );
      },
    );
  }
}
