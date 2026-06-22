import 'dart:async' show unawaited;
import 'dart:math' show pi, sin;

import 'package:flutter/material.dart';
import 'package:lauschi/core/database/app_database.dart' as db;
import 'package:lauschi/core/database/tile_item_repository.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/tiles/widgets/audio_tile.dart';

/// Grid of episode cards with auto-scroll to the next unheard episode.
class EpisodeGrid extends StatefulWidget {
  const EpisodeGrid({
    required this.episodes,
    required this.activeUri,
    required this.isPlaying,
    required this.isActive,
    required this.onCardTap,
    required this.albumProgress,
    super.key,
    this.nextUnheardId,
    this.showEpisodeTitles = false,
    this.onExpiredTap,
  });

  final List<db.TileItem> episodes;
  final String? nextUnheardId;
  final String? activeUri;
  final bool isPlaying;
  final bool isActive;
  final void Function(db.TileItem card) onCardTap;
  final bool showEpisodeTitles;

  /// Called when an expired tile is tapped. Shows an explanation modal.
  final VoidCallback? onExpiredTap;

  /// Computes playback progress (0.0-1.0) for a card.
  final double Function(db.TileItem card) albumProgress;

  @override
  State<EpisodeGrid> createState() => _EpisodeGridState();
}

class _EpisodeGridState extends State<EpisodeGrid>
    with TickerProviderStateMixin {
  static const _crossAxisSpacing = 12.0;
  static const _mainAxisSpacing = 16.0;
  static const _gridPadding = EdgeInsets.fromLTRB(
    AppSpacing.screenH,
    AppSpacing.sm,
    AppSpacing.screenH,
    AppSpacing.xxl,
  );

  final _scrollController = ScrollController();

  String? _lastScrolledToId;

  late final AnimationController _glowController;
  late final AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _glowController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    );
    unawaited(_glowController.repeat(reverse: true));
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _glowController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToWeiter({
    required BoxConstraints constraints,
    required int columns,
    required bool animate,
  }) {
    final targetId = widget.nextUnheardId;
    if (targetId == null) return;

    _lastScrolledToId = targetId;

    final index = widget.episodes.indexWhere((e) => e.id == targetId);
    if (index <= 0) return;

    final row = index ~/ columns;
    final availableWidth = constraints.maxWidth - _gridPadding.horizontal;
    final itemHeight =
        (availableWidth - (columns - 1) * _crossAxisSpacing) / columns;
    final offset =
        _gridPadding.top +
        row * (itemHeight + _mainAxisSpacing) -
        constraints.maxHeight * 0.3;
    if (offset <= 0) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      final clamped = offset.clamp(
        0.0,
        _scrollController.position.maxScrollExtent,
      );
      if (animate) {
        unawaited(
          _scrollController.animateTo(
            clamped,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutCubic,
          ),
        );
      } else {
        _scrollController.jumpTo(clamped);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = kidGridColumns(constraints.maxWidth);

        if (widget.nextUnheardId != null &&
            widget.nextUnheardId != _lastScrolledToId) {
          final isSubsequent = _lastScrolledToId != null;
          _scrollToWeiter(
            constraints: constraints,
            columns: columns,
            animate: isSubsequent,
          );
          if (isSubsequent) {
            unawaited(_pulseController.forward(from: 0));
          }
        }

        return GridView.builder(
          controller: _scrollController,
          padding: _gridPadding,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: _crossAxisSpacing,
            mainAxisSpacing: _mainAxisSpacing,
          ),
          itemCount: widget.episodes.length,
          itemBuilder: (context, index) {
            final card = widget.episodes[index];
            final expired = isItemExpired(card);
            final isCurrentCard =
                !expired &&
                widget.isActive &&
                widget.activeUri == card.providerUri;
            final isNext = !expired && card.id == widget.nextUnheardId;

            final tile = TileItem(
              key: ValueKey(card.id),
              title: card.customTitle ?? card.title,
              coverUrl: card.coverUrl,
              isPlaying: isCurrentCard && widget.isPlaying,
              isPaused: isCurrentCard && !widget.isPlaying,
              isHeard: card.isHeard,
              isExpired: expired,
              progress: expired ? 0 : widget.albumProgress(card),
              kidMode: true,
              episodeNumber: card.episodeNumber,
              showEpisodeTitles: widget.showEpisodeTitles,
              onTap:
                  expired
                      ? widget.onExpiredTap ?? () {}
                      : () => widget.onCardTap(card),
            );

            if (!isNext) return tile;

            return AnimatedBuilder(
              animation: Listenable.merge([_glowController, _pulseController]),
              builder: (context, child) {
                final glowT = Curves.easeInOut.transform(
                  _glowController.value,
                );
                final pulseT = sin(_pulseController.value * pi);

                return Transform.scale(
                  scale: 1.0 + 0.05 * pulseT,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Positioned.fill(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: const BorderRadius.all(
                              AppRadius.card,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: AppColors.accent.withAlpha(
                                  (40 + 40 * glowT).round(),
                                ),
                                blurRadius: 10 + 6 * glowT,
                                spreadRadius: 1 + 3 * glowT,
                              ),
                            ],
                          ),
                        ),
                      ),
                      child!,
                      Positioned(
                        top: -8,
                        left: 0,
                        right: 0,
                        child: Center(
                          child: ExcludeSemantics(
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: AppColors.accent,
                                borderRadius: const BorderRadius.all(
                                  AppRadius.pill,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.3),
                                    blurRadius: 4,
                                    offset: const Offset(0, 2),
                                  ),
                                ],
                              ),
                              child: const Text(
                                '▶ Weiter',
                                style: TextStyle(
                                  fontFamily: 'Nunito',
                                  fontSize: 13,
                                  fontWeight: FontWeight.w800,
                                  color: AppColors.textOnPrimary,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
              child: tile,
            );
          },
        );
      },
    );
  }
}
