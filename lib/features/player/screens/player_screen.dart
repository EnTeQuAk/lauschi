import 'dart:async' show unawaited;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/player/player_provider.dart';
import 'package:lauschi/features/player/player_state.dart';
import 'package:lauschi/features/player/widgets/next_episode_preview.dart';
import 'package:lauschi/features/player/widgets/player_error_dialog.dart';
import 'package:shimmer/shimmer.dart';

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
    // Show error dialog and pop player on dismiss.
    ref.listen(
      playerProvider.select((s) => s.error),
      (prev, next) {
        if (next != null && next != prev) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!context.mounted) return;
            unawaited(
              showPlayerErrorDialog(context, ref: ref, error: next).then((_) {
                if (context.mounted) Navigator.of(context).pop();
              }),
            );
          });
        }
      },
    );

    final state = ref.watch(
      playerProvider.select(
        (s) => (
          track: s.track,
          isPlaying: s.isPlaying,
          isLoading: s.isLoading,
          isAdvancing: s.isAdvancing,
          nextEpisodeCoverUrl: s.nextEpisodeCoverUrl,
          durationMs: s.durationMs,
          positionMs: s.positionMs,
        ),
      ),
    );
    final notifier = ref.read(playerProvider.notifier);
    final track = state.track;

    return Scaffold(
      body: SafeArea(
        child: GestureDetector(
          // Swipe down anywhere to close. Low velocity threshold for kids.
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
                  // Large close button for kids
                  const _CloseButton(),
                  // Album art (shimmer placeholder while loading)
                  Expanded(
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.xxl,
                        ),
                        child:
                            state.isLoading
                                ? const _AlbumArtSkeleton()
                                : _AlbumArt(artworkUrl: track?.artworkUrl),
                      ),
                    ),
                  ),
                  // Track info
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.xl,
                    ),
                    child: _TrackInfo(track: track),
                  ),
                  // Auto-advance indicator: skip icon + next cover thumbnail
                  if (state.isAdvancing)
                    Padding(
                      padding: const EdgeInsets.only(top: AppSpacing.md),
                      child: NextEpisodePreview(
                        coverUrl: state.nextEpisodeCoverUrl,
                      ),
                    ),
                  const SizedBox(height: AppSpacing.lg),
                  // Progress bar with its own ticker for smooth interpolation.
                  // Isolated to avoid rebuilding album art / controls at 60fps.
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.xl,
                    ),
                    child: _InterpolatedProgress(
                      onSeek: (ms) => unawaited(notifier.seek(ms)),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  // Controls
                  _PlayerControls(
                    isPlaying: state.isPlaying,
                    onPrevious: state.isLoading ? null : notifier.prevTrack,
                    onTogglePlay: state.isLoading ? null : notifier.togglePlay,
                    onNext: state.isLoading ? null : notifier.nextTrack,
                  ),
                  const SizedBox(height: AppSpacing.xxl),
                ],
              ),
              // Loading overlay
              if (state.isLoading) const _LoadingOverlay(),
            ],
          ),
        ),
      ),
    );
  }
}

/// Progress bar with its own ticker — only this widget rebuilds at 60fps.
class _InterpolatedProgress extends ConsumerStatefulWidget {
  const _InterpolatedProgress({required this.onSeek});
  final ValueChanged<int> onSeek;

  @override
  ConsumerState<_InterpolatedProgress> createState() =>
      _InterpolatedProgressState();
}

class _InterpolatedProgressState extends ConsumerState<_InterpolatedProgress>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final _position = ValueNotifier<int>(0);

  /// Last position reported by the SDK. When this changes, we re-anchor
  /// the interpolation to the new server position and interpolate forward
  /// from there. Prevents drift between ticker and SDK from causing
  /// periodic backward snaps.
  int _anchorMs = 0;
  DateTime _anchorTime = DateTime.now();

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    unawaited(_ticker.start());
  }

  @override
  void dispose() {
    _ticker.dispose();
    _position.dispose();
    super.dispose();
  }

  void _onTick(Duration elapsed) {
    final state = ref.read(playerProvider);
    final serverMs = state.positionMs;

    // Re-anchor when the SDK reports a new position (different from our
    // last anchor). This happens every few seconds on state_changed events.
    if (serverMs != _anchorMs) {
      _anchorMs = serverMs;
      _anchorTime = DateTime.now();
    }

    if (!state.isPlaying || state.durationMs <= 0) {
      _position.value = serverMs;
      return;
    }

    // Interpolate forward from the anchor at real-time speed.
    final deltaMs = DateTime.now().difference(_anchorTime).inMilliseconds;
    _position.value = (_anchorMs + deltaMs).clamp(0, state.durationMs);
  }

  /// Update local position during drag without sending a seek command.
  /// Prevents the slider from snapping back while the user is dragging.
  void _scrubTo(int ms) {
    _anchorMs = ms;
    _anchorTime = DateTime.now();
    _position.value = ms;
  }

  /// Commit the seek when the user releases the slider.
  void _seekTo(int ms) {
    _scrubTo(ms);
    widget.onSeek(ms);
  }

  @override
  Widget build(BuildContext context) {
    final durationMs = ref.watch(
      playerProvider.select((s) => s.durationMs),
    );
    // RepaintBoundary isolates the slider's frequent repaints (every
    // position tick) from the rest of the player screen. See #227.
    return RepaintBoundary(
      child: ValueListenableBuilder<int>(
        valueListenable: _position,
        builder:
            (context, positionMs, _) => _ProgressBar(
              positionMs: positionMs,
              durationMs: durationMs,
              onScrub: _scrubTo,
              onSeek: _seekTo,
            ),
      ),
    );
  }
}

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

class _AlbumArt extends StatelessWidget {
  const _AlbumArt({this.artworkUrl});

  final String? artworkUrl;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 400, maxHeight: 400),
      child: AspectRatio(
        aspectRatio: 1,
        child: Hero(
          tag: playerArtworkHeroTag,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: const BorderRadius.all(Radius.circular(20)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.15),
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            clipBehavior: Clip.antiAlias,
            child:
                artworkUrl != null
                    ? CachedNetworkImage(
                      imageUrl: artworkUrl!,
                      fit: BoxFit.cover,
                      memCacheWidth: 600,
                    )
                    : const ColoredBox(
                      color: AppColors.surfaceDim,
                      child: Icon(
                        Icons.music_note_rounded,
                        size: 72,
                        color: AppColors.textSecondary,
                      ),
                    ),
          ),
        ),
      ),
    );
  }
}

/// Shimmer placeholder for album art while the backend is loading.
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

/// Semi-transparent overlay with a spinner, shown while the backend
/// connects. Absorbs taps so the kid can't hammer controls.
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
          maxLines: 1,
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

class _ProgressBar extends StatelessWidget {
  const _ProgressBar({
    required this.positionMs,
    required this.durationMs,
    required this.onScrub,
    required this.onSeek,
  });

  final int positionMs;
  final int durationMs;
  final void Function(int positionMs) onScrub;
  final void Function(int positionMs) onSeek;

  double get _progress =>
      durationMs > 0 ? (positionMs / durationMs).clamp(0.0, 1.0) : 0.0;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SliderTheme(
          data: const SliderThemeData(
            trackHeight: 6,
            activeTrackColor: AppColors.primary,
            inactiveTrackColor: AppColors.surfaceDim,
            thumbColor: AppColors.primary,
            thumbShape: RoundSliderThumbShape(enabledThumbRadius: 8),
            overlayShape: RoundSliderOverlayShape(overlayRadius: 20),
            trackShape: RoundedRectSliderTrackShape(),
          ),
          child: Semantics(
            label: 'Wiedergabeposition',
            child: Slider(
              value: _progress,
              onChanged: (value) {
                if (durationMs > 0) {
                  onScrub((value * durationMs).round());
                }
              },
              onChangeEnd: (value) {
                if (durationMs > 0) {
                  onSeek((value * durationMs).round());
                }
              },
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _formatDuration(positionMs),
                style: const TextStyle(
                  fontFamily: 'Nunito',
                  fontSize: 12,
                  color: AppColors.textSecondary,
                ),
              ),
              Text(
                _formatDuration(durationMs),
                style: const TextStyle(
                  fontFamily: 'Nunito',
                  fontSize: 12,
                  color: AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  static String _formatDuration(int ms) {
    final total = Duration(milliseconds: ms);
    final hours = total.inHours;
    final minutes = total.inMinutes.remainder(60);
    final seconds = total.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:$seconds';
    }
    return '$minutes:$seconds';
  }
}

class _PlayerControls extends StatelessWidget {
  const _PlayerControls({
    required this.isPlaying,
    required this.onPrevious,
    required this.onTogglePlay,
    required this.onNext,
  });

  final bool isPlaying;
  final VoidCallback? onPrevious;
  final VoidCallback? onTogglePlay;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // Previous
        IconButton(
          key: const Key('prev_track_button'),
          onPressed: onPrevious,
          icon: const Icon(Icons.skip_previous_rounded),
          iconSize: 64,
          tooltip: 'Vorheriges Kapitel',
          style: IconButton.styleFrom(
            minimumSize: const Size(88, 88),
            foregroundColor: AppColors.textPrimary,
          ),
        ),
        const SizedBox(width: AppSpacing.xl),
        // Play/pause
        _PlayPauseButton(
          key: const Key('play_pause_button'),
          isPlaying: isPlaying,
          onPressed: onTogglePlay,
        ),
        const SizedBox(width: AppSpacing.xl),
        // Next
        IconButton(
          key: const Key('next_track_button'),
          onPressed: onNext,
          icon: const Icon(Icons.skip_next_rounded),
          iconSize: 64,
          tooltip: 'Nächstes Kapitel',
          style: IconButton.styleFrom(
            minimumSize: const Size(88, 88),
            foregroundColor: AppColors.textPrimary,
          ),
        ),
      ],
    );
  }
}

class _PlayPauseButton extends StatelessWidget {
  const _PlayPauseButton({
    required this.isPlaying,
    required this.onPressed,
    super.key,
  });

  final bool isPlaying;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: isPlaying ? 'Pause' : 'Abspielen',
      button: true,
      excludeSemantics: true,
      child: SizedBox(
        width: 112,
        height: 112,
        child: FilledButton(
          onPressed: onPressed,
          style: FilledButton.styleFrom(
            shape: const CircleBorder(),
            padding: EdgeInsets.zero,
          ),
          child: Icon(
            isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
            size: 64,
            color: AppColors.textOnPrimary,
          ),
        ),
      ),
    );
  }
}
