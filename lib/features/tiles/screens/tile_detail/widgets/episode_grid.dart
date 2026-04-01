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

class _EpisodeGridState extends State<EpisodeGrid> {
  static const _crossAxisSpacing = 12.0;
  static const _mainAxisSpacing = 16.0;

  final _controller = ScrollController();
  bool _didInitialScroll = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = kidGridColumns(constraints.maxWidth);

        // Scroll to the "Weiter" episode on first open.
        if (!_didInitialScroll && widget.nextUnheardId != null) {
          _didInitialScroll = true;
          final index = widget.episodes.indexWhere(
            (e) => e.id == widget.nextUnheardId,
          );
          if (index > 0) {
            final row = index ~/ columns;
            final availableWidth =
                constraints.maxWidth - 2 * AppSpacing.screenH;
            final itemHeight =
                (availableWidth - (columns - 1) * _crossAxisSpacing) / columns;
            final offset =
                AppSpacing.sm +
                row * (itemHeight + _mainAxisSpacing) -
                constraints.maxHeight * 0.3;
            if (offset > 0) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (_controller.hasClients) {
                  _controller.jumpTo(
                    offset.clamp(0.0, _controller.position.maxScrollExtent),
                  );
                }
              });
            }
          }
        }

        return GridView.builder(
          controller: _controller,
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.screenH,
            AppSpacing.sm,
            AppSpacing.screenH,
            AppSpacing.xxl,
          ),
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

            return Stack(
              clipBehavior: Clip.none,
              children: [
                if (isNext)
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: const BorderRadius.all(AppRadius.card),
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.accent.withAlpha(60),
                            blurRadius: 12,
                            spreadRadius: 2,
                          ),
                        ],
                      ),
                    ),
                  ),
                TileItem(
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
                ),
                if (isNext)
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
            );
          },
        );
      },
    );
  }
}
