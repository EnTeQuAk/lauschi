import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lauschi/core/connectivity/connectivity_provider.dart';
import 'package:lauschi/core/database/tile_repository.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/nfc/nfc_pair_dialog.dart';
import 'package:lauschi/core/router/app_router.dart';
import 'package:lauschi/core/settings/debug_settings.dart';
import 'package:lauschi/core/settings/kid_settings.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/player/player_provider.dart';
import 'package:lauschi/features/player/widgets/now_playing_bar.dart';
import 'package:lauschi/features/tiles/screens/tile_detail/widgets/child_tile_grid.dart';
import 'package:lauschi/features/tiles/screens/tile_detail/widgets/episode_grid.dart';
import 'package:lauschi/features/tiles/screens/tile_detail/widgets/tile_group_header.dart';
import 'package:lauschi/features/tiles/tile_actions.dart';
import 'package:lauschi/features/tiles/widgets/unavailable_dialog.dart';

const _tag = 'TileDetailScreen';

/// Group/series drill-down — shows all episodes in order.
///
/// Heard episodes are visually muted. The tile's Weiter card, where the
/// kid continues, is highlighted: a gentle nudge without being
/// prescriptive.
class TileDetailScreen extends ConsumerWidget {
  const TileDetailScreen({required this.tileId, super.key});

  final String tileId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groupAsync = ref.watch(tileByIdProvider(tileId));
    final childTilesAsync = ref.watch(childTilesProvider(tileId));
    final episodesAsync = ref.watch(tileItemsProvider(tileId));
    final weiter = ref.watch(tileWeiterProvider(tileId));
    // Grid view of the play state: no position ticks, no per-second
    // rebuilds of the episode grid.
    final playerState = ref.watch(playerGridStateProvider);
    final playerNotifier = ref.read(playerProvider.notifier);
    final isOnline = ref.watch(isOnlineProvider);

    final nfcEnabled =
        ref
            .watch(debugSettingsProvider)
            .whenOrNull(data: (s) => s.nfcEnabled) ??
        false;
    final showTitles = ref.watch(showEpisodeTitlesProvider).value ?? false;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // Header with back button + optional NFC pair action
            groupAsync.when(
              data:
                  (group) => TileGroupHeader(
                    title: group?.title ?? '',
                    onBack: () {
                      if (context.canPop()) {
                        context.pop();
                      } else {
                        context.go(AppRoutes.kidHome);
                      }
                    },
                    onNfcPair:
                        nfcEnabled && group != null
                            ? () => showNfcPairDialog(
                              context,
                              ref: ref,
                              targetType: 'group',
                              targetId: group.id,
                              targetLabel: group.title,
                            )
                            : null,
                  ),
              loading:
                  () => TileGroupHeader(
                    title: '',
                    onBack: () {
                      if (context.canPop()) {
                        context.pop();
                      } else {
                        context.go(AppRoutes.kidHome);
                      }
                    },
                  ),
              error:
                  (_, _) => TileGroupHeader(
                    title: '',
                    onBack: () {
                      if (context.canPop()) {
                        context.pop();
                      } else {
                        context.go(AppRoutes.kidHome);
                      }
                    },
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

            // Content: child tiles (if nested) or episodes (if leaf).
            // Children take priority over items for mixed tiles.
            Expanded(
              child: childTilesAsync.when(
                data: (childTiles) {
                  if (childTiles.isNotEmpty) {
                    // This tile has child tiles: show them as a grid.
                    // Tapping a child navigates deeper (recursive).
                    return ChildTileGrid(
                      children: childTiles,
                      onTileTap: (child) {
                        Log.info(
                          _tag,
                          'Child tile tapped',
                          data: {
                            'childId': child.id,
                            'parentId': tileId,
                            'title': child.title,
                          },
                        );
                        unawaited(context.push(AppRoutes.tileDetail(child.id)));
                      },
                    );
                  }

                  // No children: show episodes (leaf tile, current behavior).
                  return episodesAsync.when(
                    data: (episodes) {
                      if (episodes.isEmpty) {
                        return const _EmptyGroupState();
                      }
                      return EpisodeGrid(
                        episodes: episodes,
                        weiterId: weiter?.id,
                        player: playerState,
                        showEpisodeTitles: showTitles,
                        onUnavailableTap: () => showUnavailableDialog(context),
                        onCardTap:
                            (card) => playCardAndOpenPlayer(
                              context,
                              ref,
                              card,
                              logTag: _tag,
                              tileId: tileId,
                            ),
                      );
                    },
                    loading:
                        () => const Center(child: CircularProgressIndicator()),
                    error:
                        (_, _) => const Center(
                          child: Icon(
                            Icons.error_outline_rounded,
                            size: 48,
                            color: AppColors.textSecondary,
                          ),
                        ),
                  );
                },
                loading: () => const Center(child: CircularProgressIndicator()),
                error:
                    (_, _) => const Center(
                      child: Icon(
                        Icons.error_outline_rounded,
                        size: 48,
                        color: AppColors.textSecondary,
                      ),
                    ),
              ),
            ),

            // Now-playing bar (same as home)
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
                  playerState.track != null
                      ? NowPlayingBar(
                        key: const ValueKey('now-playing'),
                        track: playerState.track!,
                        isPlaying: playerState.isPlaying,
                        onTap: () => context.push(AppRoutes.player),
                        onTogglePlay: playerNotifier.togglePlay,
                      )
                      : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Inline widgets ──────────────────────────────────────────────────────

class _EmptyGroupState extends StatelessWidget {
  const _EmptyGroupState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(AppSpacing.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.layers_rounded, size: 48, color: AppColors.primarySoft),
            SizedBox(height: AppSpacing.md),
            Text(
              'Noch keine Folgen',
              style: TextStyle(
                fontFamily: 'Nunito',
                fontSize: 16,
                color: AppColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
