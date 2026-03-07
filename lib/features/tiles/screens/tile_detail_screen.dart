import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lauschi/core/connectivity/connectivity_provider.dart';
import 'package:lauschi/core/database/app_database.dart' as db;
import 'package:lauschi/core/database/tile_item_repository.dart';
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
import 'package:lauschi/features/tiles/widgets/audio_tile.dart';

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
                  (group) => _GroupHeader(
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
                  () => _GroupHeader(
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
                  (_, _) => _GroupHeader(
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

            // Episode grid
            Expanded(
              child: episodesAsync.when(
                data: (allEpisodes) {
                  // Hide expired episodes from kids entirely.
                  // Parents see them in tile_edit_screen.
                  final episodes =
                      allEpisodes.where((e) => !isItemExpired(e)).toList();
                  if (episodes.isEmpty) {
                    return const _EmptyGroupState();
                  }
                  final nextId = nextUnheard?.id;
                  return _EpisodeGrid(
                    episodes: episodes,
                    nextUnheardId: nextId,
                    activeUri: playerState.activeContextUri,
                    isPlaying: playerState.isPlaying,
                    isActive: playerState.track != null,
                    showEpisodeTitles: showTitles,
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
                        isAdvancing: playerState.isAdvancing,
                        nextEpisodeCoverUrl: playerState.nextEpisodeCoverUrl,
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

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({
    required this.title,
    required this.onBack,
    this.onNfcPair,
  });

  final String title;
  final VoidCallback onBack;

  /// If non-null, shows an NFC pair button in the header.
  final VoidCallback? onNfcPair;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.lg,
        AppSpacing.screenH,
        AppSpacing.sm,
      ),
      child: Row(
        children: [
          SizedBox(
            width: 72,
            height: 72,
            child: Semantics(
              label: 'Zurück',
              button: true,
              child: Material(
                color: AppColors.surfaceDim,
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: onBack,
                  child: const Icon(
                    Icons.chevron_left_rounded,
                    size: 48,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: 'Nunito',
                fontSize: 26,
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary,
                letterSpacing: -0.3,
              ),
            ),
          ),
          if (onNfcPair != null)
            IconButton(
              onPressed: onNfcPair,
              icon: const Icon(Icons.nfc_rounded),
              iconSize: 22,
              style: IconButton.styleFrom(
                minimumSize: const Size(44, 44),
                foregroundColor: AppColors.textSecondary,
              ),
              tooltip: 'NFC-Tag verknüpfen',
            ),
        ],
      ),
    );
  }
}

class _EpisodeGrid extends StatefulWidget {
  const _EpisodeGrid({
    required this.episodes,
    required this.activeUri,
    required this.isPlaying,
    required this.isActive,
    required this.onCardTap,
    this.nextUnheardId,
    this.showEpisodeTitles = false,
  });

  final List<db.TileItem> episodes;
  final String? nextUnheardId;
  final String? activeUri;
  final bool isPlaying;
  final bool isActive;
  final void Function(db.TileItem card) onCardTap;
  final bool showEpisodeTitles;

  @override
  State<_EpisodeGrid> createState() => _EpisodeGridState();
}

class _EpisodeGridState extends State<_EpisodeGrid> {
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

        // Scroll to the "Weiter" episode on first open so kids don't have
        // to hunt through hundreds of tiles. Only runs once per screen
        // visit; returning from the player keeps the user's scroll position.
        if (!_didInitialScroll && widget.nextUnheardId != null) {
          _didInitialScroll = true;
          final index = widget.episodes.indexWhere(
            (e) => e.id == widget.nextUnheardId,
          );
          if (index > 0) {
            final row = index ~/ columns;
            // Item height from grid math (aspect ratio 1:1)
            final availableWidth =
                constraints.maxWidth - 2 * AppSpacing.screenH;
            final itemHeight =
                (availableWidth - (columns - 1) * _crossAxisSpacing) / columns;
            // Place the target row ~30% from the top of the viewport
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
            final isCurrentCard =
                widget.isActive && widget.activeUri == card.providerUri;
            final isNext = card.id == widget.nextUnheardId;

            return Stack(
              clipBehavior: Clip.none,
              children: [
                TileItem(
                  key: ValueKey(card.id),
                  title: card.customTitle ?? card.title,
                  coverUrl: card.coverUrl,
                  isPlaying: isCurrentCard && widget.isPlaying,
                  isPaused: isCurrentCard && !widget.isPlaying,
                  isHeard: card.isHeard,
                  progress: _albumProgress(card),
                  kidMode: true,
                  episodeNumber: card.episodeNumber,
                  showEpisodeTitles: widget.showEpisodeTitles,
                  onTap: () => widget.onCardTap(card),
                ),
                // "Weiter" badge on next unheard episode
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

// ---------------------------------------------------------------------------
// Providers scoped to a group — manual StreamProviders to avoid Drift type
// resolution issues with riverpod_generator.
// ---------------------------------------------------------------------------

/// Cards in a specific group, ordered by episode number.
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
