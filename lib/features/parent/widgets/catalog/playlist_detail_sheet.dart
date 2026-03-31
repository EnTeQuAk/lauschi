import 'dart:async' show unawaited;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/spotify/spotify_api.dart';
import 'package:lauschi/core/spotify/spotify_session.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/parent/widgets/catalog/catalog_helpers.dart';

const _tag = 'PlaylistDetailSheet';

/// Bottom sheet showing playlist tracks and an add button.
class PlaylistDetailSheet extends ConsumerStatefulWidget {
  const PlaylistDetailSheet({
    required this.playlist,
    required this.isAdded,
    required this.onAdd,
    super.key,
  });

  final SpotifyPlaylist playlist;
  final bool isAdded;
  final VoidCallback onAdd;

  @override
  ConsumerState<PlaylistDetailSheet> createState() =>
      _PlaylistDetailSheetState();
}

class _PlaylistDetailSheetState extends ConsumerState<PlaylistDetailSheet> {
  List<SpotifyTrack>? _tracks;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_loadTracks());
  }

  Future<void> _loadTracks() async {
    try {
      final detail = await ref
          .read(spotifySessionProvider.notifier)
          .api
          .getPlaylist(widget.playlist.id);
      if (!mounted) return;
      setState(() {
        _tracks = detail?.tracks;
        _loading = false;
      });
    } on Exception catch (e) {
      Log.error(_tag, 'Failed to load playlist detail', exception: e);
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.3,
      maxChildSize: 0.9,
      expand: false,
      builder: (context, scrollController) {
        return Column(
          children: [
            Container(
              margin: const EdgeInsets.only(top: 8, bottom: 4),
              width: 40,
              height: 4,
              decoration: const BoxDecoration(
                color: AppColors.surfaceDim,
                borderRadius: BorderRadius.all(Radius.circular(2)),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.screenH,
                AppSpacing.sm,
                AppSpacing.screenH,
                AppSpacing.md,
              ),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: const BorderRadius.all(Radius.circular(8)),
                    child: SizedBox(
                      width: 64,
                      height: 64,
                      child:
                          widget.playlist.imageUrl != null
                              ? CachedNetworkImage(
                                imageUrl: widget.playlist.imageUrl!,
                                fit: BoxFit.cover,
                              )
                              : const ColoredBox(
                                color: AppColors.surfaceDim,
                                child: Icon(Icons.music_note_rounded),
                              ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.playlist.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: 'Nunito',
                            fontWeight: FontWeight.w700,
                            fontSize: 16,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${widget.playlist.ownerName} · '
                          '${widget.playlist.totalTracks} Titel',
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
                  const SizedBox(width: AppSpacing.sm),
                  if (widget.isAdded)
                    const Icon(Icons.check_rounded, color: AppColors.success)
                  else
                    FilledButton(
                      onPressed: widget.onAdd,
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.md,
                          vertical: AppSpacing.xs,
                        ),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: const Text('Hinzufügen'),
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child:
                  _loading
                      ? const Center(child: CircularProgressIndicator())
                      : _tracks == null || _tracks!.isEmpty
                      ? const Center(
                        child: Text(
                          'Keine Titel verfügbar.',
                          style: TextStyle(
                            fontFamily: 'Nunito',
                            color: AppColors.textSecondary,
                          ),
                        ),
                      )
                      : ListView.builder(
                        controller: scrollController,
                        padding: const EdgeInsets.only(
                          bottom: AppSpacing.xxl,
                          top: AppSpacing.xs,
                        ),
                        itemCount: _tracks!.length,
                        itemBuilder: (context, index) {
                          final track = _tracks![index];
                          return ListTile(
                            dense: true,
                            leading: SizedBox(
                              width: 24,
                              child: Text(
                                '${index + 1}',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontFamily: 'Nunito',
                                  fontSize: 13,
                                  color: AppColors.textSecondary,
                                ),
                              ),
                            ),
                            title: Text(
                              track.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontFamily: 'Nunito',
                                fontSize: 14,
                              ),
                            ),
                            subtitle:
                                track.artistNames != null
                                    ? Text(
                                      track.artistNames!,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontFamily: 'Nunito',
                                        fontSize: 12,
                                        color: AppColors.textSecondary,
                                      ),
                                    )
                                    : null,
                            trailing: Text(
                              formatCatalogDuration(track.durationMs),
                              style: const TextStyle(
                                fontFamily: 'Nunito',
                                fontSize: 13,
                                color: AppColors.textSecondary,
                              ),
                            ),
                          );
                        },
                      ),
            ),
          ],
        );
      },
    );
  }
}
