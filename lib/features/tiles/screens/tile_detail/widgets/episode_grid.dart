import 'dart:math' show pi, sin;

import 'package:flutter/material.dart';
import 'package:lauschi/core/database/app_database.dart' as db;
import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/router/app_router.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/player/player_provider.dart'
    show PlayerGridState;
import 'package:lauschi/features/tiles/card_indicator.dart';
import 'package:lauschi/features/tiles/widgets/audio_tile.dart';

const _tag = 'EpisodeGrid';

/// Grid of a tile's episodes, with the Weiter card marked.
///
/// It scrolls at two moments only: to the Weiter card when the screen
/// opens, and to it again when the kid comes back from a screen on top
/// (the player) and the Weiter card moved meanwhile. Data changes while
/// the grid is visible never move it.
class EpisodeGrid extends StatefulWidget {
  const EpisodeGrid({
    required this.episodes,
    required this.weiterId,
    required this.player,
    required this.onCardTap,
    required this.onUnavailableTap,
    super.key,
    this.showEpisodeTitles = false,
  });

  final List<db.TileItem> episodes;

  /// The tile's Weiter card, null when nothing is playable.
  final String? weiterId;
  final PlayerGridState player;
  final void Function(db.TileItem card) onCardTap;
  final bool showEpisodeTitles;

  /// Called when an unavailable card is tapped. Shows an explanation.
  final VoidCallback onUnavailableTap;

  @override
  State<EpisodeGrid> createState() => _EpisodeGridState();
}

class _EpisodeGridState extends State<EpisodeGrid>
    with SingleTickerProviderStateMixin, RouteAware {
  static const _crossAxisSpacing = 12.0;
  static const _mainAxisSpacing = 16.0;
  static const _gridPadding = EdgeInsets.fromLTRB(
    AppSpacing.screenH,
    AppSpacing.sm,
    AppSpacing.screenH,
    AppSpacing.xxl,
  );

  final _scrollController = ScrollController();
  late final AnimationController _pulseController;

  /// The grid's last layout size, for turning a card index into an offset.
  BoxConstraints? _constraints;

  /// The grid has scrolled to the Weiter card once since it opened.
  bool _openedAtWeiter = false;

  /// The Weiter card when a screen was pushed on top, to pulse the badge
  /// on return when it moved meanwhile.
  String? _weiterWhenCovered;

  ModalRoute<void>? _route;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != _route) {
      if (_route != null) routeObserver.unsubscribe(this);
      _route = route;
      if (route != null) routeObserver.subscribe(this, route);
    }
  }

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    _pulseController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didPushNext() => _weiterWhenCovered = widget.weiterId;

  @override
  void didPopNext() {
    // A covered page doesn't rebuild. It catches up with what changed
    // meanwhile (e.g. the Weiter card moving when an episode finished)
    // in its first frame back, so compare after that frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final moved = widget.weiterId != _weiterWhenCovered;
      _weiterWhenCovered = null;
      // Unchanged Weiter (a dialog, or a short peek into the player):
      // the kid's view stays where they left it.
      if (!moved) return;
      _scrollToWeiter(animate: true);
      _pulseController.forward(from: 0);
    });
  }

  /// Scroll so the Weiter card sits in the upper third of the viewport.
  /// Runs after the next frame, when the grid has its layout.
  void _scrollToWeiter({required bool animate}) {
    final targetId = widget.weiterId;
    if (targetId == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final constraints = _constraints;
      if (!mounted || constraints == null || !_scrollController.hasClients) {
        return;
      }
      final index = widget.episodes.indexWhere((e) => e.id == targetId);
      if (index < 0) return;
      final offset = weiterScrollOffset(
        index: index,
        columns: kidGridColumns(constraints.maxWidth),
        width: constraints.maxWidth,
        viewportHeight: constraints.maxHeight,
      ).clamp(0.0, _scrollController.position.maxScrollExtent);
      Log.debug(
        _tag,
        'Scroll to Weiter',
        data: {'itemId': targetId, 'index': '$index', 'animate': '$animate'},
      );
      if (animate) {
        _scrollController.animateTo(
          offset,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
        );
      } else {
        _scrollController.jumpTo(offset);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_openedAtWeiter && widget.weiterId != null) {
      _openedAtWeiter = true;
      _scrollToWeiter(animate: false);
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        _constraints = constraints;
        final columns = kidGridColumns(constraints.maxWidth);

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
            final indicator = cardIndicator(
              card,
              player: widget.player,
              weiterId: widget.weiterId,
            );
            final tile = AudioTile(
              key: ValueKey(card.id),
              title: card.customTitle ?? card.title,
              coverUrl: card.coverUrl,
              indicator: indicator,
              kidMode: true,
              episodeNumber: card.episodeNumber,
              showEpisodeTitles: widget.showEpisodeTitles,
              onTap:
                  indicator.status == CardStatus.unavailable
                      ? widget.onUnavailableTap
                      : () => widget.onCardTap(card),
            );
            return indicator.isWeiter ? _weiterDecoration(tile) : tile;
          },
        );
      },
    );
  }

  /// Glow, a "Weiter" pill, and the pulse when the badge moved.
  Widget _weiterDecoration(Widget tile) {
    return AnimatedBuilder(
      animation: _pulseController,
      builder: (context, child) {
        final pulseT = sin(_pulseController.value * pi);

        return Transform.scale(
          scale: 1.0 + 0.03 * pulseT,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: const BorderRadius.all(AppRadius.card),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.primary.withValues(alpha: 0.45),
                      blurRadius: 12,
                      spreadRadius: 1,
                    ),
                  ],
                ),
                child: child,
              ),
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
                        borderRadius: const BorderRadius.all(AppRadius.pill),
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
  }
}

/// Scroll offset that puts the card at [index] in the upper third of a
/// [viewportHeight] tall grid of square cards, [columns] wide in [width].
/// Negative for cards near the top, which the caller clamps to 0.
double weiterScrollOffset({
  required int index,
  required int columns,
  required double width,
  required double viewportHeight,
}) {
  const padding = _EpisodeGridState._gridPadding;
  const spacing = _EpisodeGridState._crossAxisSpacing;
  final itemHeight =
      (width - padding.horizontal - (columns - 1) * spacing) / columns;
  final row = index ~/ columns;
  return padding.top +
      row * (itemHeight + _EpisodeGridState._mainAxisSpacing) -
      viewportHeight * 0.3;
}
