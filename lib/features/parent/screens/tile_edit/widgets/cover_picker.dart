import 'dart:async' show unawaited;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lauschi/core/feature_flags.dart';
import 'package:lauschi/core/spotify/spotify_session.dart';
import 'package:lauschi/core/theme/app_theme.dart';

/// Cover image picker for tile editing.
///
/// Shows the current cover, episode cover thumbnails, and optional
/// artist images fetched from Spotify. Tapping a thumbnail sets
/// the cover URL.
class CoverPicker extends ConsumerStatefulWidget {
  const CoverPicker({
    required this.controller,
    required this.episodeCovers,
    required this.onChanged,
    super.key,
    this.artistIds = const [],
    this.onAutoSave,
  });

  final TextEditingController controller;

  /// Distinct cover URLs already present in the group's episodes.
  final List<String> episodeCovers;

  /// Spotify artist IDs to fetch artist images from.
  final List<String> artistIds;

  /// Called when any cover value changes (marks the form dirty).
  final VoidCallback onChanged;

  /// Called immediately when an episode thumbnail is tapped; auto-saves
  /// without requiring the user to tap a separate "Speichern" button.
  final Future<void> Function()? onAutoSave;

  @override
  ConsumerState<CoverPicker> createState() => _CoverPickerState();
}

class _CoverPickerState extends ConsumerState<CoverPicker> {
  String get _currentUrl => widget.controller.text.trim();
  final _artistImages = <String>[];
  bool _artistImagesFetched = false;

  @override
  void initState() {
    super.initState();
    unawaited(_fetchArtistImages());
  }

  @override
  void didUpdateWidget(CoverPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.artistIds != widget.artistIds) {
      _artistImagesFetched = false;
      _artistImages.clear();
      unawaited(_fetchArtistImages());
    }
  }

  Future<void> _fetchArtistImages() async {
    if (!FeatureFlags.enableSpotify) return;
    if (widget.artistIds.isEmpty || _artistImagesFetched) return;
    _artistImagesFetched = true;

    final api = ref.read(spotifySessionProvider.notifier).api;

    for (final id in widget.artistIds) {
      try {
        final url = await api.getArtistImage(id);
        if (url != null && mounted) {
          setState(() => _artistImages.add(url));
        }
      } on Exception {
        // Artist image fetch is best-effort.
      }
    }
  }

  void _pickCover(String url) {
    widget.controller.text = url;
    widget.onChanged();
    if (widget.onAutoSave != null) unawaited(widget.onAutoSave!());
  }

  void _clearCover() {
    widget.controller.clear();
    widget.onChanged();
    if (widget.onAutoSave != null) unawaited(widget.onAutoSave!());
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            ClipRRect(
              borderRadius: const BorderRadius.all(AppRadius.card),
              child: SizedBox(
                width: 72,
                height: 72,
                child:
                    _currentUrl.isNotEmpty
                        ? CachedNetworkImage(
                          imageUrl: _currentUrl,
                          fit: BoxFit.cover,
                          errorWidget: (_, _, _) => const _CoverPlaceholder(),
                        )
                        : const _CoverPlaceholder(),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Kachel-Cover',
                    style: TextStyle(
                      fontFamily: 'Nunito',
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _currentUrl.isNotEmpty
                        ? 'Tippe auf eine Folge unten zum Ändern'
                        : 'Wähle das Cover einer Folge',
                    style: const TextStyle(
                      fontFamily: 'Nunito',
                      fontSize: 12,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  if (_currentUrl.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    GestureDetector(
                      onTap: _clearCover,
                      child: const Text(
                        'Entfernen',
                        style: TextStyle(
                          fontFamily: 'Nunito',
                          fontSize: 12,
                          color: AppColors.error,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),

        if (_artistImages.isNotEmpty)
          _coverChipRow('Vom Künstler', _artistImages),

        if (widget.episodeCovers.isNotEmpty)
          _coverChipRow('Von Folgen', widget.episodeCovers),
      ],
    );
  }

  Widget _coverChipRow(String label, List<String> urls) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: AppSpacing.sm),
        Text(
          label,
          style: const TextStyle(
            fontFamily: 'Nunito',
            fontSize: 11,
            color: AppColors.textSecondary,
          ),
        ),
        const SizedBox(height: 4),
        SizedBox(
          height: 52,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: urls.length,
            separatorBuilder: (_, _) => const SizedBox(width: 6),
            itemBuilder: (context, index) {
              final url = urls[index];
              final isSelected = _currentUrl == url;
              return GestureDetector(
                onTap: () => _pickCover(url),
                child: Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    borderRadius: const BorderRadius.all(AppRadius.card),
                    border:
                        isSelected
                            ? Border.all(color: AppColors.primary, width: 2.5)
                            : null,
                  ),
                  child: ClipRRect(
                    borderRadius: const BorderRadius.all(AppRadius.card),
                    child: CachedNetworkImage(
                      imageUrl: url,
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _CoverPlaceholder extends StatelessWidget {
  const _CoverPlaceholder();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: AppColors.surfaceDim,
      child: Icon(
        Icons.layers_rounded,
        size: 32,
        color: AppColors.textSecondary,
      ),
    );
  }
}
