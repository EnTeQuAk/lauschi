import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/player/player_provider.dart';
import 'package:lauschi/features/player/player_state.dart';
import 'package:lauschi/features/player/screens/player/widgets/interpolated_progress.dart';
import 'package:lauschi/features/player/screens/player/widgets/player_album_art.dart';
import 'package:lauschi/features/player/screens/player/widgets/player_controls.dart';
import 'package:shimmer/shimmer.dart';

/// What [PlayerScreen] rebuilds on: the track, and the play/loading
/// flags that drive the controls and skeleton. Deliberately excludes
/// positionMs/durationMs — the progress bar is [InterpolatedProgress],
/// which animates itself from its own controller, so folding the
/// per-second position tick in here would rebuild the album art, hero,
/// and controls once a second for nothing.
({TrackInfo? track, bool isPlaying, bool isLoading}) playerScreenView(
  PlaybackState s,
) => (track: s.track, isPlaying: s.isPlaying, isLoading: s.isLoading);

/// Full-screen player with large album art, controls, and progress bar.
///
/// Expands from the now-playing bar via hero animation on the album art.
/// Swipe down or tap the collapse handle to return to the card grid.
class PlayerScreen extends ConsumerStatefulWidget {
  const PlayerScreen({super.key});

  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends ConsumerState<PlayerScreen> {
  @override
  Widget build(BuildContext context) {
    // This screen's content just failed and the error dialog handled it
    // (error went non-null then back to null on dismiss); leaving the
    // kid on a dead player screen helps nobody, so pop back to the grid.
    // PlayerErrorHost owns showing the dialog itself.
    ref.listen(playerProvider.select((s) => s.error), (prev, next) {
      if (prev != null && next == null && context.mounted && context.canPop()) {
        context.pop();
      }
    });

    final state = ref.watch(playerProvider.select(playerScreenView));
    final notifier = ref.read(playerProvider.notifier);
    final hasPrev = notifier.hasPrevTrack;
    final hasNext = notifier.hasNextTrack;
    final track = state.track;

    return Scaffold(
      body: SafeArea(
        child: GestureDetector(
          onVerticalDragEnd: (details) {
            if (details.primaryVelocity != null &&
                details.primaryVelocity! > 100) {
              Navigator.of(context).pop();
            }
          },
          child: Stack(
            children: [
              Column(
                children: [
                  const _CloseButton(),
                  Expanded(
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.xxl,
                        ),
                        child:
                            state.isLoading
                                ? const _AlbumArtSkeleton()
                                : PlayerAlbumArt(artworkUrl: track?.artworkUrl),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.xl,
                    ),
                    child: _TrackInfo(track: track),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.xl,
                    ),
                    child: InterpolatedProgress(
                      onSeek: (ms) => unawaited(notifier.seek(ms)),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  PlayerControls(
                    isPlaying: state.isPlaying,
                    onPrevious:
                        state.isLoading || !hasPrev ? null : notifier.prevTrack,
                    onTogglePlay: state.isLoading ? null : notifier.togglePlay,
                    onNext:
                        state.isLoading || !hasNext ? null : notifier.nextTrack,
                  ),
                  const SizedBox(height: AppSpacing.xxl),
                ],
              ),
              if (state.isLoading) const _LoadingOverlay(),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Inline widgets (all <50 lines) ──────────────────────────────────────────

class _CloseButton extends StatelessWidget {
  const _CloseButton();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.lg,
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: SizedBox(
          width: 72,
          height: 72,
          child: Material(
            color: AppColors.surfaceDim,
            shape: const CircleBorder(),
            child: Semantics(
              label: 'Zurück',
              button: true,
              child: InkWell(
                key: const Key('player_close_button'),
                customBorder: const CircleBorder(),
                onTap: () => Navigator.of(context).pop(),
                child: const Icon(
                  Icons.chevron_left_rounded,
                  size: 48,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AlbumArtSkeleton extends StatelessWidget {
  const _AlbumArtSkeleton();

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 400, maxHeight: 400),
      child: AspectRatio(
        aspectRatio: 1,
        child: Hero(
          tag: playerArtworkHeroTag,
          child: Shimmer.fromColors(
            baseColor: AppColors.surfaceDim,
            highlightColor: AppColors.surface,
            child: Container(
              decoration: const BoxDecoration(
                color: AppColors.surfaceDim,
                borderRadius: BorderRadius.all(Radius.circular(20)),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LoadingOverlay extends StatelessWidget {
  const _LoadingOverlay();

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: AbsorbPointer(
        child: ColoredBox(
          color: AppColors.background.withValues(alpha: 0.6),
          child: const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(color: AppColors.primary),
                SizedBox(height: AppSpacing.md),
                Text(
                  'Wird geladen …',
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 16,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TrackInfo extends StatelessWidget {
  const _TrackInfo({this.track});

  final TrackInfo? track;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          track?.name ?? '',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontFamily: 'Nunito',
            fontWeight: FontWeight.w700,
            fontSize: 22,
            color: AppColors.textPrimary,
          ),
        ),
        if (track?.artist != null) ...[
          const SizedBox(height: AppSpacing.xs),
          Text(
            track!.artist!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontFamily: 'Nunito',
              fontSize: 15,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ],
    );
  }
}
