import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lauschi/core/connectivity/connectivity_provider.dart';
import 'package:lauschi/core/database/app_database.dart' as db;
import 'package:lauschi/core/database/tile_item_repository.dart';
import 'package:lauschi/core/database/tile_repository.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/router/app_router.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/player/player_provider.dart';
import 'package:lauschi/features/player/widgets/now_playing_bar.dart';
import 'package:lauschi/features/player/widgets/player_error_dialog.dart';
import 'package:lauschi/features/tiles/widgets/audio_tile.dart';
import 'package:lauschi/features/tiles/widgets/tile_card.dart';

const _tag = 'KidHomeScreen';

/// Album playback progress 0.0–1.0 based on stored track position.
double _albumProgress(db.TileItem card) {
  if (card.isHeard || card.totalTracks <= 0 || card.lastTrackNumber <= 0) {
    return 0;
  }
  return (card.lastTrackNumber / card.totalTracks).clamp(0.0, 1.0);
}

/// The single kid-facing screen: group + card grid + now-playing bar.
///
/// Groups appear as series tiles (drill-down to episodes).
/// Ungrouped cards appear as regular audio cards.
class KidHomeScreen extends ConsumerWidget {
  const KidHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groupsAsync = ref.watch(allTilesProvider);
    final ungroupedAsync = ref.watch(ungroupedItemsProvider);
    // Only rebuild for play state / track changes, not position updates.
    final playerState = ref.watch(
      playerProvider.select(
        (s) => (
          isPlaying: s.isPlaying,
          isReady: s.isReady,
          hasTrack: s.track != null,
          activeContextUri: s.activeContextUri,
        ),
      ),
    );
    final playerNotifier = ref.read(playerProvider.notifier);
    final isOnline = ref.watch(isOnlineProvider);

    // Show error dialog as a side effect, not inline in the tree.
    ref.listen(
      playerProvider.select((s) => s.error),
      (prev, next) {
        if (next != null && next != prev) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (context.mounted) {
              unawaited(
                showPlayerErrorDialog(context, ref: ref, error: next),
              );
            }
          });
        }
      },
    );

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.screenH,
                AppSpacing.lg,
                AppSpacing.screenH,
                AppSpacing.md,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Meine Hörspiele',
                    style: TextStyle(
                      fontFamily: 'Nunito',
                      fontSize: 28,
                      fontWeight: FontWeight.w800,
                      color: AppColors.textPrimary,
                      letterSpacing: -0.3,
                    ),
                  ),
                  IconButton(
                    onPressed: () {
                      Log.info(_tag, 'Parent button tapped');
                      unawaited(context.push(AppRoutes.parentDashboard));
                    },
                    icon: const Icon(Icons.settings_rounded),
                    iconSize: 22,
                    style: IconButton.styleFrom(
                      minimumSize: const Size(44, 44),
                      foregroundColor: AppColors.textSecondary,
                    ),
                    tooltip: 'Eltern-Bereich',
                  ),
                ],
              ),
            ),

            // Offline indicator
            if (!isOnline)
              Semantics(
                liveRegion: true,
                label: 'Kein Internet',
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.screenH,
                    vertical: AppSpacing.sm,
                  ),
                  color: AppColors.surfaceDim,
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.cloud_off_rounded,
                        size: 16,
                        color: AppColors.textSecondary,
                      ),
                      SizedBox(width: AppSpacing.xs),
                      Text(
                        'Kein Internet',
                        style: TextStyle(
                          fontFamily: 'Nunito',
                          fontSize: 13,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            // Connecting indicator — subtle, doesn't take prime real estate.
            if (!playerState.isReady && isOnline)
              Semantics(
                label: 'Verbindung wird hergestellt',
                child: const Padding(
                  padding: EdgeInsets.only(bottom: AppSpacing.xs),
                  child: SizedBox(
                    height: 2,
                    child: LinearProgressIndicator(
                      backgroundColor: Colors.transparent,
                      color: AppColors.primary,
                    ),
                  ),
                ),
              ),

            // Grid
            Expanded(
              child: _combineAsync(groupsAsync, ungroupedAsync, (
                groups,
                ungrouped,
              ) {
                if (groups.isEmpty && ungrouped.isEmpty) {
                  return const _EmptyState();
                }
                return _HomeGrid(
                  groups: groups,
                  ungrouped: ungrouped,
                  activeUri: playerState.activeContextUri,
                  isPlaying: playerState.isPlaying,
                  isActive: playerState.hasTrack,
                  onCardTap:
                      playerState.isReady
                          ? (card) {
                            Log.info(
                              _tag,
                              'Card tapped',
                              data: {
                                'cardId': card.id,
                                'title': card.customTitle ?? card.title,
                              },
                            );
                            unawaited(playerNotifier.playCard(card.id));
                            unawaited(context.push(AppRoutes.player));
                          }
                          : null,
                  onGroupTap: (group) {
                    Log.info(
                      _tag,
                      'Tile tapped',
                      data: {
                        'tileId': group.id,
                        'title': group.title,
                      },
                    );
                    unawaited(context.push(AppRoutes.tileDetail(group.id)));
                  },
                );
              }),
            ),

            // Now-playing bar
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              transitionBuilder:
                  (child, animation) => SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0, 1),
                      end: Offset.zero,
                    ).animate(
                      CurvedAnimation(
                        parent: animation,
                        curve: Curves.easeOutCubic,
                      ),
                    ),
                    child: child,
                  ),
              child:
                  playerState.hasTrack
                      ? Consumer(
                        builder: (context, ref, _) {
                          final s = ref.watch(
                            playerProvider.select(
                              (s) => (
                                track: s.track,
                                isPlaying: s.isPlaying,
                                isAdvancing: s.isAdvancing,
                                nextCover: s.nextEpisodeCoverUrl,
                              ),
                            ),
                          );
                          if (s.track == null) {
                            return const SizedBox.shrink();
                          }
                          return NowPlayingBar(
                            key: const ValueKey('now-playing'),
                            track: s.track!,
                            isPlaying: s.isPlaying,
                            isAdvancing: s.isAdvancing,
                            nextEpisodeCoverUrl: s.nextCover,
                            onTap: () => context.push(AppRoutes.player),
                            onTogglePlay: playerNotifier.togglePlay,
                          );
                        },
                      )
                      : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }

  /// Combine two AsyncValues. Shows loading/error if either isn't ready.
  Widget _combineAsync<A, B>(
    AsyncValue<A> a,
    AsyncValue<B> b,
    Widget Function(A, B) builder,
  ) {
    if (a is AsyncLoading || b is AsyncLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (a is AsyncError || b is AsyncError) {
      return const Center(
        child: Icon(
          Icons.error_outline_rounded,
          size: 48,
          color: AppColors.textSecondary,
        ),
      );
    }
    return builder(a.requireValue, b.requireValue);
  }
}

class _HomeGrid extends StatelessWidget {
  const _HomeGrid({
    required this.groups,
    required this.ungrouped,
    required this.activeUri,
    required this.isPlaying,
    required this.isActive,
    required this.onCardTap,
    required this.onGroupTap,
  });

  final List<db.Tile> groups;
  final List<db.TileItem> ungrouped;
  final String? activeUri;
  final bool isPlaying;
  final bool isActive;
  final void Function(db.TileItem)? onCardTap;
  final void Function(db.Tile) onGroupTap;

  @override
  Widget build(BuildContext context) {
    final itemCount = groups.length + ungrouped.length;

    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = kidGridColumns(constraints.maxWidth);

        return GridView.builder(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenH),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
          ),
          itemCount: itemCount,
          itemBuilder: (context, index) {
            // Groups first, then ungrouped cards
            if (index < groups.length) {
              final group = groups[index];
              return _GroupGridItem(
                key: ValueKey('group-${group.id}'),
                group: group,
                onTap: () => onGroupTap(group),
              );
            }
            final card = ungrouped[index - groups.length];
            final expired = isItemExpired(card);
            final isCurrentCard = isActive && activeUri == card.providerUri;
            return TileItem(
              key: ValueKey(card.id),
              title: card.customTitle ?? card.title,
              coverUrl: card.coverUrl,
              isPlaying: !expired && isCurrentCard && isPlaying,
              isPaused: !expired && isCurrentCard && !isPlaying,
              isHeard: card.isHeard,
              isExpired: expired,
              progress: _albumProgress(card),
              kidMode: true,
              episodeNumber: card.episodeNumber,
              onTap:
                  onCardTap != null && !expired
                      ? () => onCardTap!(card)
                      : () {},
            );
          },
        );
      },
    );
  }
}

/// Grid item that watches its own episode count — clean separation.
class _GroupGridItem extends ConsumerWidget {
  const _GroupGridItem({required this.group, required this.onTap, super.key});

  final db.Tile group;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progressMap = ref.watch(tileProgressProvider);
    final stats = progressMap[group.id];
    final total = stats?.total ?? 0;
    final heard = stats?.heard ?? 0;
    final progress = total > 0 ? (heard / total) : 0.0;

    return TileCard(
      title: group.title,
      episodeCount: total,
      coverUrl: group.coverUrl,
      progress: progress,
      contentType: group.contentType,
      kidMode: true,
      onTap: onTap,
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset(
              'assets/images/branding/lauschi-mascot.png',
              width: 140,
              height: 140,
            ),
            const SizedBox(height: AppSpacing.lg),
            const Text(
              'Füge dein erstes Hörspiel hinzu',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'Nunito',
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            const Text(
              'Öffne den Eltern-Bereich, um Hörspiele hinzuzufügen.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'Nunito',
                fontSize: 15,
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: AppSpacing.xl),
            FilledButton.icon(
              onPressed: () => context.push(AppRoutes.parentDashboard),
              icon: const Icon(Icons.add_rounded),
              label: const Text('Hörspiel hinzufügen'),
            ),
          ],
        ),
      ),
    );
  }
}
