import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lauschi/core/ard/ard_models.dart';
import 'package:lauschi/core/theme/app_theme.dart';

/// Synopsis and average duration badge for an ARD show.
class ArdShowMeta extends StatelessWidget {
  const ArdShowMeta({
    required this.show,
    required this.episodesAsync,
    super.key,
  });

  final ArdProgramSet show;
  final AsyncValue<ArdItemPage> episodesAsync;

  @override
  Widget build(BuildContext context) {
    final synopsis = show.synopsis;

    final avgDuration = episodesAsync.whenOrNull(
      data: (page) {
        final playable = page.items.where((i) => i.bestAudioUrl != null);
        if (playable.isEmpty) return null;
        final total = playable.fold<int>(0, (sum, i) => sum + i.duration);
        return total ~/ playable.length;
      },
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.screenH,
        AppSpacing.md,
        AppSpacing.screenH,
        AppSpacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (avgDuration != null && avgDuration > 0) ...[
            () {
              final cat = _durationCategory(avgDuration);
              return Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.sm,
                  vertical: 3,
                ),
                decoration: const BoxDecoration(
                  color: AppColors.surfaceDim,
                  borderRadius: BorderRadius.all(Radius.circular(6)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(cat.icon, size: 14, color: AppColors.textSecondary),
                    const SizedBox(width: 4),
                    Text(
                      cat.label,
                      style: const TextStyle(
                        fontFamily: 'Nunito',
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              );
            }(),
            const SizedBox(height: AppSpacing.sm),
          ],
          if (synopsis != null && synopsis.isNotEmpty)
            Text(
              synopsis,
              style: const TextStyle(
                fontFamily: 'Nunito',
                fontSize: 13,
                color: AppColors.textSecondary,
                height: 1.4,
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
        ],
      ),
    );
  }
}

/// Duration category with icon and label.
({IconData icon, String label}) _durationCategory(int avgSeconds) {
  final minutes = avgSeconds ~/ 60;
  if (minutes <= 6) {
    return (icon: Icons.nightlight_round, label: '~$minutes Min.');
  } else if (minutes <= 20) {
    return (icon: Icons.menu_book_rounded, label: '~$minutes Min.');
  } else if (minutes <= 35) {
    return (icon: Icons.theater_comedy_rounded, label: '~$minutes Min.');
  } else {
    return (icon: Icons.headphones_rounded, label: '~$minutes Min.');
  }
}
