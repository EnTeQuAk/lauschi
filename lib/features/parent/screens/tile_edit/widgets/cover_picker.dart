import 'dart:async' show unawaited;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart' show listEquals, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lauschi/core/feature_flags.dart';
import 'package:lauschi/core/spotify/spotify_session.dart';
import 'package:lauschi/core/theme/app_theme.dart';

/// Whether an artist-image fetch's results should still be applied: the
/// picker is still mounted and the ids we [ranFor] still match the
/// [current] ones. A different id set means didUpdateWidget already
/// cleared the images and kicked off a fresh fetch, so this batch is
/// stale and would otherwise mix a previous artist's images into the new
/// set.
@visibleForTesting
bool shouldApplyArtistImages({
  required List<String> ranFor,
  required List<String> current,
  required bool mounted,
}) => mounted && listEquals(ranFor, current);

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
    widget.controller.addListener(_onControllerChanged);
    unawaited(_fetchArtistImages());
  }

  @override
  void didUpdateWidget(CoverPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
    }
    if (!listEquals(oldWidget.artistIds, widget.artistIds)) {
      _artistImagesFetched = false;
      _artistImages.clear();
      unawaited(_fetchArtistImages());
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  /// The preview, the selection highlight, and the "Entfernen" affordance
  /// all read `controller.text`, so rebuild whenever it changes. Without
  /// this the parent's deferred (post-frame) controller init leaves an
  /// existing cover invisible until some unrelated setState rebuilds us.
  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _fetchArtistImages() async {
    if (!FeatureFlags.enableSpotify) return;
    if (widget.artistIds.isEmpty || _artistImagesFetched) return;
    _artistImagesFetched = true;

    final ranFor = widget.artistIds;
    final api = ref.read(spotifySessionProvider.notifier).api;

    final futures = ranFor.map((id) async {
      try {
        return await api.getArtistImage(id);
      } on Exception {
        return null; // Best-effort.
      }
    });
    final results = await Future.wait(futures);
    if (!shouldApplyArtistImages(
      ranFor: ranFor,
      current: widget.artistIds,
      mounted: mounted,
    )) {
      return;
    }
    final urls = results.whereType<String>().toList();
    if (urls.isNotEmpty) setState(() => _artistImages.addAll(urls));
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
                    Semantics(
                      button: true,
                      label: 'Cover entfernen',
                      child: InkWell(
                        onTap: _clearCover,
                        borderRadius: BorderRadius.circular(4),
                        child: const Text(
                          'Entfernen',
                          style: TextStyle(
                            fontFamily: 'Nunito',
                            fontSize: 12,
                            color: AppColors.error,
                          ),
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
                      errorWidget:
                          (_, _, _) => const ColoredBox(
                            color: AppColors.surfaceDim,
                            child: Icon(
                              Icons.broken_image_outlined,
                              size: 20,
                              color: AppColors.textSecondary,
                            ),
                          ),
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
