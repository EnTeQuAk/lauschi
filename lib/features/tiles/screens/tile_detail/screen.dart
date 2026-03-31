import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lauschi/core/connectivity/connectivity_provider.dart';
import 'package:lauschi/core/database/app_database.dart' as db;
import 'package:lauschi/core/database/tile_repository.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/nfc/nfc_pair_dialog.dart';
import 'package:lauschi/core/router/app_router.dart';
import 'package:lauschi/core/settings/debug_settings.dart';
import 'package:lauschi/core/settings/kid_settings.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/player/player_provider.dart';
import 'package:lauschi/features/player/widgets/now_playing_bar.dart';
import 'package:lauschi/features/player/widgets/player_error_dialog.dart';
import 'package:lauschi/features/tiles/screens/tile_detail/widgets/child_tile_grid.dart';
import 'package:lauschi/features/tiles/screens/tile_detail/widgets/episode_grid.dart';
import 'package:lauschi/features/tiles/screens/tile_detail/widgets/tile_group_header.dart';

const _tag = 'TileDetailScreen';

/// Album playback progress 0.0–1.0 based on stored track position.
/// Returns 0 for cards that haven't been started or are fully heard.
double _albumProgress(db.TileItem card) {
  if (card.isHeard || card.totalTracks <= 0 || card.lastTrackNumber <= 0) {
    return 0;
  }
  return (card.lastTrackNumber / card.totalTracks).clamp(0.0, 1.0);
}

/// Group/series drill-down — shows all episodes in order.
///
/// Heard episodes are visually muted. First unheard episode is highlighted
/// as the "next" — a gentle nudge without being prescriptive.
class TileDetailScreen extends ConsumerWidget {
  const TileDetailScreen({required this.tileId, super.key});

  final String tileId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groupAsync = ref.watch(tileByIdProvider(tileId));
    final childTilesAsync = ref.watch(childTilesProvider(tileId));
    final episodesAsync = ref.watch(tileItemsProvider(tileId));
    final nextUnheard = ref.watch(tileNextUnheardProvider(tileId));
    final playerState = ref.watch(playerProvider);
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
                        unawaited(
                          context.push(AppRoutes.tileDetail(child.id)),
                        );
                      },
                    );
                  }

                  // No children: show episodes (leaf tile, current behavior).
                  return episodesAsync.when(
                    data: (episodes) {
                      if (episodes.isEmpty) {
                        return const _EmptyGroupState();
                      }
                      final nextId = nextUnheard?.id;
                      return EpisodeGrid(
                        episodes: episodes,
                        nextUnheardId: nextId,
                        activeUri: playerState.activeContextUri,
                        isPlaying: playerState.isPlaying,
                        isActive: playerState.track != null,
                        showEpisodeTitles: showTitles,
                        albumProgress: _albumProgress,
                        onExpiredTap: () => _showExpiredModal(context),
                        onCardTap: (card) {
                          Log.info(
                            _tag,
                            'Episode tapped',
                            data: {
                              'cardId': card.id,
                              'tileId': tileId,
                              'title': card.customTitle ?? card.title,
                            },
                          );
                          unawaited(playerNotifier.playCard(card.id));
                          unawaited(context.push(AppRoutes.player));
                        },
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

void _showExpiredModal(BuildContext context) {
  unawaited(
    showDialog<void>(
      context: context,
      builder:
          (_) => Dialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.xl,
                AppSpacing.xl,
                AppSpacing.xl,
                AppSpacing.lg,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Image.asset(
                    'assets/images/branding/lauschi-confused.png',
                    width: 80,
                    height: 80,
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  const Text(
                    'Gerade nicht verfügbar',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: 'Nunito',
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  const Text(
                    'Diese Folge ist gerade nicht abrufbar. '
                    'Manchmal werden Inhalte später wieder '
                    'freigeschaltet.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: 'Nunito',
                      fontSize: 15,
                      color: AppColors.textSecondary,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xl),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: FilledButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text(
                        'Verstanden',
                        style: TextStyle(
                          fontFamily: 'Nunito',
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
    ),
  );
}

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

final tileItemsProvider = StreamProvider.family<List<db.TileItem>, String>(
  (ref, tileId) {
    return ref.watch(tileRepositoryProvider).watchItems(tileId);
  },
);

/// The group metadata for a given ID — reactive to DB changes.
final tileByIdProvider = StreamProvider.family<db.Tile?, String>((
  ref,
  tileId,
) {
  return ref.watch(tileRepositoryProvider).watchById(tileId);
});

/// The episode to show the "Weiter" badge on.
///
/// Priority:
/// 1. Most recently played in-progress episode (has saved position from DB,
///    meaning 30s play threshold was met)
/// 2. First unheard episode (sequential fallback)
final tileNextUnheardProvider = Provider.family<db.TileItem?, String>((
  ref,
  tileId,
) {
  final episodes = ref.watch(tileItemsProvider(tileId)).value ?? [];

  // Find the most recently played episode that's still in progress.
  // Only considers episodes with a saved position (30s threshold met).
  db.TileItem? inProgress;
  for (final ep in episodes) {
    if (!ep.isHeard && ep.lastPlayedAt != null && ep.lastPositionMs > 0) {
      if (inProgress == null ||
          ep.lastPlayedAt!.isAfter(inProgress.lastPlayedAt!)) {
        inProgress = ep;
      }
    }
  }
  if (inProgress != null) return inProgress;

  // Nothing in progress — first unheard episode.
  for (final ep in episodes) {
    if (!ep.isHeard) return ep;
  }
  return null;
});
