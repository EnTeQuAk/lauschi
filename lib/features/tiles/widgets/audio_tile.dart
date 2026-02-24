import 'dart:async' show unawaited;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/core/utils/title_cleaner.dart';

/// A single card in the kid-mode grid.
///
/// Shows album art with a title below. Animated press feedback.
/// Active card gets a green border + play badge.
class TileItem extends StatefulWidget {
  const TileItem({
    required this.title,
    required this.onTap,
    super.key,
    this.coverUrl,
    this.isPlaying = false,
    this.isPaused = false,
    this.isHeard = false,
    this.progress = 0,
    this.kidMode = false,
    this.episodeNumber,
    this.showEpisodeTitles = false,
  });

  final String title;
  final String? coverUrl;
  final bool isPlaying;
  final bool isPaused;

  /// Whether this episode has been heard. Dims the cover and shows ✓ badge.
  final bool isHeard;

  /// Album playback progress 0.0–1.0 (track N of M). Shown as a red bar
  /// at the bottom of the card. Not shown when 0 or when fully heard.
  final double progress;
  final VoidCallback onTap;

  /// Kid-facing mode: image-only with episode label overlay, no title text.
  final bool kidMode;

  /// Episode number from the catalog (shown as overlay in kid mode).
  final int? episodeNumber;

  /// Whether to show cleaned title alongside episode number in kid mode.
  final bool showEpisodeTitles;

  @override
  State<TileItem> createState() => _AudioCardState();
}

class _AudioCardState extends State<TileItem>
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

  Future<void> _handleTapDown(TapDownDetails _) async {
    await _controller.forward();
  }

  Future<void> _handleTapUp(TapUpDetails _) async {
    await _controller.reverse();
    widget.onTap();
  }

  Future<void> _handleTapCancel() async {
    await _controller.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final semanticLabel =
        widget.isPlaying
            ? '${widget.title}, spielt gerade'
            : widget.isPaused
            ? '${widget.title}, pausiert'
            : widget.isHeard
            ? '${widget.title}, gehört'
            : widget.title;

    return Semantics(
      label: semanticLabel,
      button: true,
      child: GestureDetector(
        onTapDown: _handleTapDown,
        onTapUp: _handleTapUp,
        onTapCancel: _handleTapCancel,
        child: AnimatedBuilder(
          animation: _scaleAnimation,
          builder:
              (context, child) => Transform.scale(
                scale: _scaleAnimation.value,
                child: child,
              ),
          child: _buildCard(),
        ),
      ),
    );
  }

  Widget _artWithOverlays() {
    return Container(
      decoration: BoxDecoration(
        borderRadius: const BorderRadius.all(AppRadius.card),
        border:
            (widget.isPlaying || widget.isPaused)
                ? Border.all(
                  color:
                      widget.isPlaying
                          ? AppColors.primary
                          : AppColors.primarySoft,
                  width: 3,
                )
                : null,
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          _CoverImage(url: widget.coverUrl),
          if (widget.isHeard && !widget.isPlaying && !widget.isPaused)
            const _HeardOverlay(),
          if (widget.isPlaying) const _PlayBadge(),
          if (widget.isPaused) const _PauseBadge(),
          if (widget.isHeard && !widget.isPlaying && !widget.isPaused)
            const _HeardBadge(),
          if (widget.progress > 0 && !widget.isHeard)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _ProgressBar(progress: widget.progress),
            ),
          // Episode label in kid mode — number + cleaned title.
          if (widget.kidMode)
            Positioned(
              left: 0,
              right: 0,
              bottom: widget.progress > 0 ? 4 : 0,
              child: _EpisodeLabel(
                number: widget.episodeNumber,
                title: widget.title,
                showTitle: widget.showEpisodeTitles,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildCard() {
    if (widget.kidMode) {
      // Image-only: the art IS the card.
      return _artWithOverlays();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AspectRatio(aspectRatio: 1, child: _artWithOverlays()),
        const SizedBox(height: 6),
        Expanded(
          child: Text(
            widget.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontFamily: 'Nunito',
              fontWeight: FontWeight.w700,
              fontSize: 13,
              height: 1.2,
              color: AppColors.textPrimary,
            ),
          ),
        ),
      ],
    );
  }
}

class _CoverImage extends StatelessWidget {
  const _CoverImage({this.url});

  final String? url;

  @override
  Widget build(BuildContext context) {
    if (url == null || url!.isEmpty) {
      return const ColoredBox(
        color: AppColors.surfaceDim,
        child: Icon(
          Icons.music_note_rounded,
          size: 48,
          color: AppColors.textSecondary,
        ),
      );
    }

    return CachedNetworkImage(
      imageUrl: url!,
      fit: BoxFit.cover,
      placeholder: (_, _) => _ShimmerPlaceholder(),
      errorWidget:
          (_, _, _) => const ColoredBox(
            color: AppColors.surfaceDim,
            child: Icon(
              Icons.music_note_rounded,
              size: 48,
              color: AppColors.textSecondary,
            ),
          ),
    );
  }
}

class _ShimmerPlaceholder extends StatefulWidget {
  @override
  State<_ShimmerPlaceholder> createState() => _ShimmerPlaceholderState();
}

class _ShimmerPlaceholderState extends State<_ShimmerPlaceholder>
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

class _PlayBadge extends StatelessWidget {
  const _PlayBadge();

  @override
  Widget build(BuildContext context) {
    return Positioned(
      right: 6,
      bottom: 6,
      child: Container(
        width: 24,
        height: 24,
        decoration: const BoxDecoration(
          color: AppColors.primary,
          shape: BoxShape.circle,
        ),
        child: const Icon(
          Icons.play_arrow_rounded,
          color: AppColors.textOnPrimary,
          size: 16,
        ),
      ),
    );
  }
}

class _PauseBadge extends StatelessWidget {
  const _PauseBadge();

  @override
  Widget build(BuildContext context) {
    return Positioned(
      right: 6,
      bottom: 6,
      child: Container(
        width: 24,
        height: 24,
        decoration: const BoxDecoration(
          color: AppColors.primarySoft,
          shape: BoxShape.circle,
        ),
        child: const Icon(
          Icons.pause_rounded,
          color: AppColors.textOnPrimary,
          size: 16,
        ),
      ),
    );
  }
}

/// Semi-transparent overlay shown on heard episodes.
class _HeardOverlay extends StatelessWidget {
  const _HeardOverlay();

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: ColoredBox(
        color: AppColors.textPrimary.withValues(alpha: 0.35),
      ),
    );
  }
}

/// Checkmark badge shown on heard episodes.
class _HeardBadge extends StatelessWidget {
  const _HeardBadge();

  @override
  Widget build(BuildContext context) {
    return Positioned(
      right: 6,
      bottom: 6,
      child: Container(
        width: 22,
        height: 22,
        decoration: BoxDecoration(
          color: AppColors.surface.withValues(alpha: 0.9),
          shape: BoxShape.circle,
        ),
        child: const Icon(
          Icons.check_rounded,
          color: AppColors.primary,
          size: 14,
        ),
      ),
    );
  }
}

/// Thin red progress bar at the bottom of the card (Netflix-style).
class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.progress});

  final double progress;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: const BorderRadius.only(
        bottomLeft: Radius.circular(8),
        bottomRight: Radius.circular(8),
      ),
      child: SizedBox(
        height: 3,
        child: LinearProgressIndicator(
          value: progress.clamp(0.0, 1.0),
          backgroundColor: Colors.black26,
          valueColor: const AlwaysStoppedAnimation<Color>(AppColors.accent),
          minHeight: 3,
        ),
      ),
    );
  }
}

/// Episode label at the bottom of kid-mode tiles.
///
/// Shows episode number (if available) and a cleaned-up title.
/// Strips "Folge N:" prefixes and "(Das Original-Hörspiel...)" suffixes
/// since those are redundant noise for kids.
class _EpisodeLabel extends StatelessWidget {
  const _EpisodeLabel({
    required this.title,
    this.number,
    this.showTitle = false,
  });

  final String title;

  /// Curated episode number from catalog. Takes priority over parsed.
  final int? number;

  /// Whether to show the cleaned title alongside the number.
  final bool showTitle;

  @override
  Widget build(BuildContext context) {
    // Curated number > parsed from title > nothing.
    final effectiveNumber = number ?? parseEpisodeNumber(title);

    // Nothing to show: no number and titles are hidden.
    if (effectiveNumber == null && !showTitle) return const SizedBox.shrink();

    String label;
    if (showTitle) {
      final cleanTitle = cleanEpisodeTitle(
        title,
        episodeNumber: effectiveNumber,
      );
      label =
          effectiveNumber != null
              ? '$effectiveNumber · $cleanTitle'
              : cleanTitle;
    } else {
      label = '$effectiveNumber';
    }

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 6),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.transparent,
            Colors.black.withAlpha(180),
          ],
        ),
        borderRadius: const BorderRadius.only(
          bottomLeft: Radius.circular(8),
          bottomRight: Radius.circular(8),
        ),
      ),
      child: Text(
        label,
        textAlign: TextAlign.center,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          fontFamily: 'Nunito',
          fontWeight: FontWeight.w800,
          fontSize: 12,
          color: Colors.white,
          height: 1.2,
        ),
      ),
    );
  }
}
