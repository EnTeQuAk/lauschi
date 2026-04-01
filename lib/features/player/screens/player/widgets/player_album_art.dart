import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/player/player_state.dart';

/// Large album art with hero animation support.
class PlayerAlbumArt extends StatelessWidget {
  const PlayerAlbumArt({super.key, this.artworkUrl});

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
