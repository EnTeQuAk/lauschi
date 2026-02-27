import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:lauschi/core/theme/app_theme.dart';

/// Size presets for [NextEpisodePreview].
enum NextEpisodePreviewSize {
  /// Small: for the now-playing bar.
  compact(iconSize: 18, coverSize: 28, radius: 4, placeholderIcon: 14),

  /// Standard: for the full player screen.
  normal(iconSize: 24, coverSize: 40, radius: 6, placeholderIcon: 20);

  const NextEpisodePreviewSize({
    required this.iconSize,
    required this.coverSize,
    required this.radius,
    required this.placeholderIcon,
  });

  final double iconSize;
  final double coverSize;
  final double radius;
  final double placeholderIcon;
}

/// Skip icon + mini cover thumbnail shown during auto-advance countdown.
class NextEpisodePreview extends StatelessWidget {
  const NextEpisodePreview({
    required this.coverUrl,
    this.size = NextEpisodePreviewSize.normal,
    super.key,
  });

  final String? coverUrl;
  final NextEpisodePreviewSize size;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.skip_next_rounded,
          size: size.iconSize,
          color: AppColors.primary,
        ),
        const SizedBox(width: 4),
        ClipRRect(
          borderRadius: BorderRadius.all(Radius.circular(size.radius)),
          child: SizedBox(
            width: size.coverSize,
            height: size.coverSize,
            child:
                coverUrl != null
                    ? CachedNetworkImage(
                      imageUrl: coverUrl!,
                      fit: BoxFit.cover,
                    )
                    : ColoredBox(
                      color: AppColors.surfaceDim,
                      child: Icon(
                        Icons.music_note_rounded,
                        size: size.placeholderIcon,
                      ),
                    ),
          ),
        ),
      ],
    );
  }
}
