import 'package:flutter/material.dart';
import 'package:lauschi/core/theme/app_theme.dart';

/// Slider progress bar with position/duration labels.
class PlayerProgressBar extends StatelessWidget {
  const PlayerProgressBar({
    required this.positionMs,
    required this.durationMs,
    required this.onScrub,
    required this.onSeek,
    super.key,
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
