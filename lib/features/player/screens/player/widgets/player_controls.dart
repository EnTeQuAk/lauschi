import 'package:flutter/material.dart';
import 'package:lauschi/core/theme/app_theme.dart';

/// Prev / Play-Pause / Next button row.
class PlayerControls extends StatelessWidget {
  const PlayerControls({
    required this.isPlaying,
    required this.onPrevious,
    required this.onTogglePlay,
    required this.onNext,
    super.key,
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
        IconButton(
          key: const Key('prev_track_button'),
          onPressed: onPrevious,
          icon: const Icon(Icons.skip_previous_rounded),
          iconSize: 64,
          tooltip: 'Vorheriges Kapitel',
          style: IconButton.styleFrom(
            minimumSize: const Size(88, 88),
            foregroundColor:
                onPrevious != null
                    ? AppColors.textPrimary
                    : AppColors.textSecondary,
          ),
        ),
        const SizedBox(width: AppSpacing.xl),
        _PlayPauseButton(
          key: const Key('play_pause_button'),
          isPlaying: isPlaying,
          onPressed: onTogglePlay,
        ),
        const SizedBox(width: AppSpacing.xl),
        IconButton(
          key: const Key('next_track_button'),
          onPressed: onNext,
          icon: const Icon(Icons.skip_next_rounded),
          iconSize: 64,
          tooltip: 'Nächstes Kapitel',
          style: IconButton.styleFrom(
            minimumSize: const Size(88, 88),
            foregroundColor:
                onNext != null
                    ? AppColors.textPrimary
                    : AppColors.textSecondary,
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
