import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:lauschi/core/spotify/spotify_api.dart';
import 'package:lauschi/core/theme/app_theme.dart';

/// A single playlist result in catalog search results.
class PlaylistResultTile extends StatelessWidget {
  const PlaylistResultTile({
    required this.playlist,
    required this.isAdded,
    required this.onAdd,
    required this.onTap,
    super.key,
  });

  final SpotifyPlaylist playlist;
  final bool isAdded;
  final VoidCallback onAdd;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cover = ClipRRect(
      borderRadius: const BorderRadius.all(Radius.circular(6)),
      child: SizedBox(
        width: 56,
        height: 56,
        child:
            playlist.imageUrl != null
                ? CachedNetworkImage(
                  imageUrl: playlist.imageUrl!,
                  fit: BoxFit.cover,
                  memCacheWidth: 112,
                )
                : const ColoredBox(
                  color: AppColors.surfaceDim,
                  child: Icon(Icons.music_note_rounded),
                ),
      ),
    );

    final trailing =
        isAdded
            ? const Icon(Icons.check_rounded, color: AppColors.success)
            : IconButton(
              onPressed: onAdd,
              icon: const Icon(Icons.add_rounded),
              color: AppColors.primary,
            );

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            cover,
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    playlist.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'Nunito',
                      fontWeight: FontWeight.w600,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${playlist.ownerName} · ${playlist.totalTracks} Titel',
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
            trailing,
          ],
        ),
      ),
    );
  }
}
