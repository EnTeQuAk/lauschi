import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:lauschi/core/theme/app_theme.dart';

/// A series/group card in the kid-mode grid.
///
/// Visually distinct from TileItem: a stacked card effect signals
/// there are multiple episodes inside. Tap to drill into the series.
class TileCard extends StatefulWidget {
  const TileCard({
    required this.title,
    required this.episodeCount,
    required this.onTap,
    super.key,
    this.coverUrl,
    this.nextEpisodeTitle,
    this.progress = 0,
    this.contentType = 'hoerspiel',
    this.kidMode = false,
  });

  final String title;
  final int episodeCount;
  final VoidCallback onTap;
  final String? coverUrl;

  /// If set, shown as a small subtitle hint (next to play).
  final String? nextEpisodeTitle;

  /// Series progress 0.0–1.0 (episodes heard / total). Red bar at bottom.
  final double progress;

  /// Content type: 'hoerspiel' or 'music'. Affects badge icon/label.
  final String contentType;

  /// Kid-facing mode: image-only with stacked art, no title/count text.
  final bool kidMode;

  @override
  State<TileCard> createState() => _GroupCardState();
}

class _GroupCardState extends State<TileCard>
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
    final countLabel =
        widget.contentType == 'music'
            ? '${widget.episodeCount} Titel'
            : widget.episodeCount == 1
            ? '1 Folge'
            : '${widget.episodeCount} Folgen';
    final label = '${widget.title}, $countLabel';

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
          child:
              widget.kidMode
                  ? _StackedArt(
                    coverUrl: widget.coverUrl,
                    progress: widget.progress,
                    isMusic: widget.contentType == 'music',
                    showBadge: false,
                  )
                  : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AspectRatio(
                        aspectRatio: 1,
                        child: _StackedArt(
                          coverUrl: widget.coverUrl,
                          progress: widget.progress,
                          isMusic: widget.contentType == 'music',
                        ),
                      ),
                      const SizedBox(height: 6),
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
                      Text(
                        widget.contentType == 'music'
                            ? '${widget.episodeCount} Titel'
                            : widget.episodeCount == 1
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
  const _StackedArt({
    this.coverUrl,
    this.progress = 0,
    this.isMusic = false,
    this.showBadge = true,
  });

  final String? coverUrl;
  final double progress;
  final bool isMusic;
  final bool showBadge;

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
        // Content type badge in top-left (hidden in kid mode)
        if (showBadge)
          Positioned(
            left: 6,
            top: 6,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
              decoration: BoxDecoration(
                color: AppColors.surface.withValues(alpha: 0.88),
                borderRadius: const BorderRadius.all(AppRadius.pill),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    isMusic
                        ? Icons.music_note_rounded
                        : Icons.auto_stories_rounded,
                    size: 10,
                    color: AppColors.primary,
                  ),
                  if (!isMusic) ...[
                    const SizedBox(width: 2),
                    const Text(
                      'Kachel',
                      style: TextStyle(
                        fontFamily: 'Nunito',
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                        color: AppColors.primary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        // Series progress bar at bottom of top card
        if (progress > 0)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: ClipRRect(
              borderRadius: const BorderRadius.only(
                bottomLeft: Radius.circular(8),
                bottomRight: Radius.circular(8),
              ),
              child: SizedBox(
                height: 3,
                child: LinearProgressIndicator(
                  value: progress.clamp(0.0, 1.0),
                  backgroundColor: Colors.black26,
                  valueColor: const AlwaysStoppedAnimation<Color>(
                    AppColors.accent,
                  ),
                  minHeight: 3,
                ),
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
      // Decode at 2x display size to keep cards sharp on high-DPI
      // without wasting memory on full-resolution CDN images. See #226.
      memCacheWidth: 400,
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
