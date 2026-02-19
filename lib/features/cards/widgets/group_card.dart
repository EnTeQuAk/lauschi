import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:lauschi/core/theme/app_theme.dart';

/// A series/group card in the kid-mode grid.
///
/// Visually distinct from AudioCard: a stacked card effect signals
/// there are multiple episodes inside. Tap to drill into the series.
class GroupCard extends StatefulWidget {
  const GroupCard({
    required this.title,
    required this.episodeCount,
    required this.onTap,
    super.key,
    this.coverUrl,
    this.nextEpisodeTitle,
  });

  final String title;
  final int episodeCount;
  final VoidCallback onTap;
  final String? coverUrl;

  /// If set, shown as a small subtitle hint (next to play).
  final String? nextEpisodeTitle;

  @override
  State<GroupCard> createState() => _GroupCardState();
}

class _GroupCardState extends State<GroupCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 150),
      vsync: this,
    );
    _scaleAnimation = Tween<double>(begin: 1, end: 0.96).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final label =
        widget.episodeCount == 1
            ? '${widget.title}, 1 Folge'
            : '${widget.title}, ${widget.episodeCount} Folgen';

    return Semantics(
      label: label,
      button: true,
      child: GestureDetector(
        onTapDown: (_) => _controller.forward(),
        onTapUp: (_) async {
          await _controller.reverse();
          widget.onTap();
        },
        onTapCancel: () => _controller.reverse(),
        child: AnimatedBuilder(
          animation: _scaleAnimation,
          builder:
              (context, child) =>
                  Transform.scale(scale: _scaleAnimation.value, child: child),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Stacked card art
              AspectRatio(
                aspectRatio: 1,
                child: _StackedArt(coverUrl: widget.coverUrl),
              ),
              const SizedBox(height: 6),
              // Title
              Flexible(
                child: Text(
                  widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: 'Nunito',
                    fontWeight: FontWeight.w800,
                    fontSize: 13,
                    height: 1.2,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              // Episode count
              Text(
                widget.episodeCount == 1
                    ? '1 Folge'
                    : '${widget.episodeCount} Folgen',
                maxLines: 1,
                style: const TextStyle(
                  fontFamily: 'Nunito',
                  fontWeight: FontWeight.w600,
                  fontSize: 11,
                  color: AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Card art with a subtle stack effect beneath it.
class _StackedArt extends StatelessWidget {
  const _StackedArt({this.coverUrl});

  final String? coverUrl;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        // Bottom card — most offset, lowest z
        const Positioned(
          left: 5,
          right: -5,
          top: 5,
          bottom: -5,
          child: _CardShadow(opacity: 0.25),
        ),
        // Middle card
        const Positioned(
          left: 2.5,
          right: -2.5,
          top: 2.5,
          bottom: -2.5,
          child: _CardShadow(opacity: 0.45),
        ),
        // Top card — the actual art
        Positioned.fill(
          child: ClipRRect(
            borderRadius: const BorderRadius.all(AppRadius.card),
            child: _cover(coverUrl),
          ),
        ),
        // "Series" indicator dot in top-left
        Positioned(
          left: 6,
          top: 6,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
            decoration: BoxDecoration(
              color: AppColors.surface.withValues(alpha: 0.88),
              borderRadius: const BorderRadius.all(AppRadius.pill),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.layers_rounded,
                  size: 10,
                  color: AppColors.primary,
                ),
                SizedBox(width: 2),
                Text(
                  'Serie',
                  style: TextStyle(
                    fontFamily: 'Nunito',
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                    color: AppColors.primary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  static Widget _cover(String? url) {
    if (url == null || url.isEmpty) {
      return const ColoredBox(
        color: AppColors.surfaceDim,
        child: Icon(
          Icons.library_music_rounded,
          size: 48,
          color: AppColors.textSecondary,
        ),
      );
    }
    return CachedNetworkImage(
      imageUrl: url,
      fit: BoxFit.cover,
    );
  }
}

class _CardShadow extends StatelessWidget {
  const _CardShadow({required this.opacity});

  final double opacity;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: const BorderRadius.all(AppRadius.card),
        color: AppColors.surfaceDim.withValues(alpha: opacity),
        boxShadow: [
          BoxShadow(
            color: AppColors.textPrimary.withValues(alpha: 0.06),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
    );
  }
}
