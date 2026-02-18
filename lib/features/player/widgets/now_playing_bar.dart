import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/player/player_state.dart';

/// Compact now-playing bar shown at the bottom of the kid home screen.
///
/// Shows album art thumbnail, track title, and play/pause button.
/// Tap the bar to expand to full player. Play/pause without expanding.
class NowPlayingBar extends StatelessWidget {
  const NowPlayingBar({
    required this.state,
    required this.onTap,
    required this.onTogglePlay,
    super.key,
  });

  final PlaybackState state;
  final VoidCallback onTap;
  final VoidCallback onTogglePlay;

  @override
  Widget build(BuildContext context) {
    final track = state.track;
    if (track == null) return const SizedBox.shrink();

    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 64,
        decoration: const BoxDecoration(
          color: AppColors.surface,
          border: Border(
            top: BorderSide(color: AppColors.surfaceDim),
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
        child: Row(
          children: [
            // Album art thumbnail
            ClipRRect(
              borderRadius: const BorderRadius.all(Radius.circular(8)),
              child: SizedBox(
                width: 44,
                height: 44,
                child: track.artworkUrl != null
                    ? Hero(
                        tag: 'player-artwork',
                        child: CachedNetworkImage(
                          imageUrl: track.artworkUrl!,
                          fit: BoxFit.cover,
                        ),
                      )
                    : const ColoredBox(
                        color: AppColors.surfaceDim,
                        child: Icon(Icons.music_note_rounded, size: 24),
                      ),
              ),
            ),
            const SizedBox(width: AppSpacing.sm + AppSpacing.xs),
            // Track info
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    track.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'Nunito',
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  Text(
                    track.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'Nunito',
                      fontSize: 12,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            // Play/pause button
            IconButton(
              onPressed: onTogglePlay,
              icon: Icon(
                state.isPlaying
                    ? Icons.pause_rounded
                    : Icons.play_arrow_rounded,
              ),
              iconSize: 32,
              style: IconButton.styleFrom(
                minimumSize: const Size(48, 48),
                foregroundColor: AppColors.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
