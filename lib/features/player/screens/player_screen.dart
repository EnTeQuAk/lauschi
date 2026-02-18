import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/player/player_provider.dart';
import 'package:lauschi/features/player/player_state.dart';

/// Full-screen player with large album art, controls, and progress bar.
///
/// Expands from the now-playing bar via hero animation on the album art.
/// Swipe down or tap the collapse handle to return to the card grid.
class PlayerScreen extends ConsumerWidget {
  const PlayerScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(playerNotifierProvider);
    final notifier = ref.read(playerNotifierProvider.notifier);
    final track = state.track;

    return Scaffold(
      body: SafeArea(
        child: GestureDetector(
          onVerticalDragEnd: (details) {
            // Swipe down to close
            if (details.primaryVelocity != null &&
                details.primaryVelocity! > 300) {
              Navigator.of(context).pop();
            }
          },
          child: Column(
            children: [
              // Collapse handle
              const _CollapseHandle(),
              // Album art
              Expanded(
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.xxl,
                    ),
                    child: _AlbumArt(artworkUrl: track?.artworkUrl),
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
              const SizedBox(height: AppSpacing.lg),
              // Progress bar
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.xl,
                ),
                child: _ProgressBar(
                  state: state,
                  onSeek: notifier.seek,
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              // Controls
              _PlayerControls(
                isPlaying: state.isPlaying,
                onPrevious: notifier.prevTrack,
                onTogglePlay: notifier.togglePlay,
                onNext: notifier.nextTrack,
              ),
              const SizedBox(height: AppSpacing.xxl),
            ],
          ),
        ),
      ),
    );
  }
}

class _CollapseHandle extends StatelessWidget {
  const _CollapseHandle();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sm),
      child: Center(
        child: Container(
          width: 36,
          height: 5,
          decoration: const BoxDecoration(
            color: AppColors.surfaceDim,
            borderRadius: BorderRadius.all(AppRadius.pill),
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
      constraints: const BoxConstraints(maxWidth: 320, maxHeight: 320),
      child: AspectRatio(
        aspectRatio: 1,
        child: Hero(
          tag: 'player-artwork',
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
            child: artworkUrl != null
                ? CachedNetworkImage(
                    imageUrl: artworkUrl!,
                    fit: BoxFit.cover,
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
        const SizedBox(height: AppSpacing.xs),
        Text(
          track?.artist ?? '',
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
    );
  }
}

class _ProgressBar extends StatelessWidget {
  const _ProgressBar({
    required this.state,
    required this.onSeek,
  });

  final PlaybackState state;
  final void Function(int positionMs) onSeek;

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
          child: Slider(
            value: state.progress,
            onChanged: (value) {
              if (state.durationMs > 0) {
                onSeek((value * state.durationMs).round());
              }
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _formatDuration(state.positionMs),
                style: const TextStyle(
                  fontFamily: 'Nunito',
                  fontSize: 12,
                  color: AppColors.textSecondary,
                ),
              ),
              Text(
                _formatDuration(state.durationMs),
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
    final minutes = total.inMinutes;
    final seconds = total.inSeconds.remainder(60).toString().padLeft(2, '0');
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
  final VoidCallback onPrevious;
  final VoidCallback onTogglePlay;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // Previous — 56dp target (school-age minimum)
        IconButton(
          onPressed: onPrevious,
          icon: const Icon(Icons.skip_previous_rounded),
          iconSize: 36,
          style: IconButton.styleFrom(
            minimumSize: const Size(56, 56),
            foregroundColor: AppColors.textPrimary,
          ),
        ),
        const SizedBox(width: AppSpacing.lg),
        // Play/pause — 72dp target (preschooler minimum)
        _PlayPauseButton(
          isPlaying: isPlaying,
          onPressed: onTogglePlay,
        ),
        const SizedBox(width: AppSpacing.lg),
        // Next — 56dp target
        IconButton(
          onPressed: onNext,
          icon: const Icon(Icons.skip_next_rounded),
          iconSize: 36,
          style: IconButton.styleFrom(
            minimumSize: const Size(56, 56),
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
  });

  final bool isPlaying;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 72,
      height: 72,
      child: FilledButton(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          shape: const CircleBorder(),
          padding: EdgeInsets.zero,
        ),
        child: Icon(
          isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
          size: 40,
          color: AppColors.textOnPrimary,
        ),
      ),
    );
  }
}
