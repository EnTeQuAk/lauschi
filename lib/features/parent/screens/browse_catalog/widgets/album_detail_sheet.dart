import 'dart:async' show unawaited;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lauschi/core/catalog/catalog_service.dart';
import 'package:lauschi/core/catalog/catalog_source.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/parent/screens/browse_catalog/widgets/catalog_helpers.dart';

const _tag = 'AlbumDetailSheet';

/// Bottom sheet showing album tracks and an add button.
class AlbumDetailSheet extends ConsumerStatefulWidget {
  const AlbumDetailSheet({
    required this.album,
    required this.isAdded,
    required this.onAdd,
    required this.source,
    super.key,
    this.catalogMatch,
  });

  final CatalogAlbumResult album;
  final bool isAdded;
  final CatalogMatch? catalogMatch;
  final VoidCallback onAdd;
  final CatalogSource source;

  @override
  ConsumerState<AlbumDetailSheet> createState() => _AlbumDetailSheetState();
}

class _AlbumDetailSheetState extends ConsumerState<AlbumDetailSheet> {
  List<CatalogTrackResult>? _tracks;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_loadTracks());
  }

  Future<void> _loadTracks() async {
    try {
      final tracks = await widget.source.getAlbumTracks(widget.album.id);
      if (!mounted) return;
      setState(() {
        _tracks = tracks.isEmpty ? null : tracks;
        _loading = false;
      });
    } on Exception catch (e) {
      Log.error(_tag, 'Failed to load album detail', exception: e);
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
                          widget.album.artworkUrlForSize(200) != null
                              ? CachedNetworkImage(
                                imageUrl: widget.album.artworkUrlForSize(200)!,
                                fit: BoxFit.cover,
                                fadeInDuration: const Duration(
                                  milliseconds: 200,
                                ),
                                placeholder:
                                    (_, _) => const ColoredBox(
                                      color: AppColors.surfaceDim,
                                    ),
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
                          widget.album.name,
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
                          widget.album.artistName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: 'Nunito',
                            fontSize: 13,
                            color: AppColors.textSecondary,
                          ),
                        ),
                        if (widget.catalogMatch != null) ...[
                          const SizedBox(height: 4),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.layers_rounded,
                                size: 12,
                                color: AppColors.primary,
                              ),
                              const SizedBox(width: 3),
                              Text(
                                widget.catalogMatch!.series.title,
                                style: const TextStyle(
                                  fontFamily: 'Nunito',
                                  fontSize: 12,
                                  color: AppColors.primary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ],
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
                                '${track.trackNumber}',
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
