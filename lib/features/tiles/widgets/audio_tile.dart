import 'package:flutter/material.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/core/utils/title_cleaner.dart';
import 'package:lauschi/features/tiles/card_indicator.dart';
import 'package:lauschi/features/tiles/widgets/cover_art.dart';

/// A single card in the kid-mode grid.
///
/// Shows album art with a title below, and renders the card's
/// [CardIndicator] as given. Animated press feedback.
class AudioTile extends StatefulWidget {
  const AudioTile({
    required this.title,
    required this.indicator,
    required this.onTap,
    super.key,
    this.coverUrl,
    this.kidMode = false,
    this.episodeNumber,
    this.showEpisodeTitles = false,
  });

  final String title;
  final String? coverUrl;

  /// What the card shows, see [cardIndicator].
  final CardIndicator indicator;

  /// Plays the card. For an unavailable card, explains why it can't.
  final VoidCallback onTap;

  /// Kid-facing mode: image-only with episode label overlay, no title text.
  final bool kidMode;

  /// Episode number from the catalog (shown as overlay in kid mode).
  final int? episodeNumber;

  /// Whether to show cleaned title alongside episode number in kid mode.
  final bool showEpisodeTitles;

  @override
  State<AudioTile> createState() => _AudioTileState();
}

class _AudioTileState extends State<AudioTile>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scaleAnimation;

  CardStatus get _status => widget.indicator.status;
  bool get _isUnavailable => _status == CardStatus.unavailable;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 150),
      vsync: this,
    );
    _scaleAnimation = Tween<double>(
      begin: 1,
      end: 0.96,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _handleTapDown(TapDownDetails _) {
    _controller.forward();
  }

  void _handleTapUp(TapUpDetails _) {
    // Fire the callback synchronously: gating it behind the reverse
    // animation's TickerFuture drops the tap whenever that ticker is
    // canceled (a second tap-down mid-reverse, or the card being
    // disposed by a DB update).
    widget.onTap();
    _controller.reverse();
  }

  void _handleTapCancel() {
    _controller.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final semanticLabel = switch (_status) {
      CardStatus.unavailable => '${widget.title}, nicht mehr verfügbar',
      CardStatus.starting => '${widget.title}, startet',
      CardStatus.playing => '${widget.title}, spielt gerade',
      CardStatus.paused => '${widget.title}, pausiert',
      CardStatus.heard => '${widget.title}, gehört',
      CardStatus.fresh => widget.title,
    };

    return Semantics(
      label: semanticLabel,
      button: !_isUnavailable,
      child: GestureDetector(
        onTapDown: _isUnavailable ? null : _handleTapDown,
        onTapUp: _isUnavailable ? null : _handleTapUp,
        onTapCancel: _isUnavailable ? null : _handleTapCancel,
        onTap: _isUnavailable ? widget.onTap : null,
        child: AnimatedBuilder(
          animation: _scaleAnimation,
          builder:
              (context, child) =>
                  Transform.scale(scale: _scaleAnimation.value, child: child),
          child: _buildCard(),
        ),
      ),
    );
  }

  Widget _artWithOverlays() {
    final progress = widget.indicator.progress;
    final borderColor = switch (_status) {
      CardStatus.playing => AppColors.primary,
      CardStatus.starting || CardStatus.paused => AppColors.primarySoft,
      _ => null,
    };
    return Container(
      decoration: BoxDecoration(
        borderRadius: const BorderRadius.all(AppRadius.card),
        border:
            borderColor != null
                ? Border.all(color: borderColor, width: 3)
                : null,
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (_isUnavailable)
            UnavailableWash(child: CoverImage(url: widget.coverUrl))
          else
            CoverImage(url: widget.coverUrl),
          if (_status == CardStatus.heard) const _HeardOverlay(),
          switch (_status) {
            CardStatus.unavailable => const _UnavailableBadge(),
            CardStatus.starting => const _StartingBadge(),
            CardStatus.playing => const _PlayBadge(),
            CardStatus.paused => const _PauseBadge(),
            CardStatus.heard => const _HeardBadge(),
            CardStatus.fresh => const SizedBox.shrink(),
          },
          if (progress > 0)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _ProgressBar(progress: progress),
            ),
          // Episode label in kid mode — number + cleaned title.
          if (widget.kidMode)
            Positioned(
              left: 0,
              right: 0,
              bottom: progress > 0 ? 4 : 0,
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
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontFamily: 'Nunito',
              fontWeight: FontWeight.w700,
              fontSize: 13,
              height: 1.1,
              color: AppColors.textPrimary,
            ),
          ),
        ),
      ],
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

/// Spinner badge while the card waits for audio.
class _StartingBadge extends StatelessWidget {
  const _StartingBadge();

  @override
  Widget build(BuildContext context) {
    return Positioned(
      right: 6,
      bottom: 6,
      child: Container(
        width: 24,
        height: 24,
        padding: const EdgeInsets.all(5),
        decoration: const BoxDecoration(
          color: AppColors.primarySoft,
          shape: BoxShape.circle,
        ),
        child: const CircularProgressIndicator(
          strokeWidth: 2,
          color: AppColors.textOnPrimary,
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
      child: ColoredBox(color: AppColors.textPrimary.withValues(alpha: 0.35)),
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

/// Hourglass badge for unavailable content.
class _UnavailableBadge extends StatelessWidget {
  const _UnavailableBadge();

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
          Icons.hourglass_empty_rounded,
          color: AppColors.textSecondary,
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
          colors: [Colors.transparent, Colors.black.withAlpha(180)],
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
