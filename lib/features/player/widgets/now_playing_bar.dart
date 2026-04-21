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
    required this.track,
    required this.isPlaying,
    required this.onTap,
    required this.onTogglePlay,
    super.key,
  });

  final TrackInfo track;
  final bool isPlaying;
  final VoidCallback onTap;
  final VoidCallback onTogglePlay;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label:
          track.artist != null
              ? 'Jetzt läuft: ${track.name} von ${track.artist}'
              : 'Jetzt läuft: ${track.name}',
      button: true,
      child: GestureDetector(
        key: const Key('now_playing_bar'),
        onTap: onTap,
        child: Container(
          height: 92,
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
                borderRadius: const BorderRadius.all(Radius.circular(10)),
                child: SizedBox(
                  width: 64,
                  height: 64,
                  child:
                      track.artworkUrl != null
                          ? Hero(
                            tag: playerArtworkHeroTag,
                            child: CachedNetworkImage(
                              imageUrl: track.artworkUrl!,
                              fit: BoxFit.cover,
                            ),
                          )
                          : const ColoredBox(
                            color: AppColors.surfaceDim,
                            child: Icon(Icons.music_note_rounded, size: 32),
                          ),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              // Track info
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      track.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'Nunito',
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    if (track.artist != null)
                      Text(
                        track.artist!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: 'Nunito',
                          fontSize: 13,
                          color: AppColors.textSecondary,
                        ),
                      ),
                  ],
                ),
              ),

              // Play/pause button
              Semantics(
                label: isPlaying ? 'Pause' : 'Abspielen',
                button: true,
                excludeSemantics: true,
                child: SizedBox(
                  width: 56,
                  height: 56,
                  child: FilledButton(
                    key: const Key('now_playing_toggle'),
                    onPressed: onTogglePlay,
                    style: FilledButton.styleFrom(
                      shape: const CircleBorder(),
                      padding: EdgeInsets.zero,
                    ),
                    child: Icon(
                      isPlaying
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      size: 32,
                      color: AppColors.textOnPrimary,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
