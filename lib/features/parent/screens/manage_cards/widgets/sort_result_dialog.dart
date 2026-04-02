import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lauschi/core/router/app_router.dart';
import 'package:lauschi/core/theme/app_theme.dart';

/// Dialog showing the results of retroactive series sorting.
class SortResultDialog extends StatelessWidget {
  const SortResultDialog({
    required this.seriesMatches,
    required this.seriesGroupIds,
    required this.totalMatched,
    super.key,
  });

  /// Series title → number of cards assigned.
  final Map<String, int> seriesMatches;

  /// Series title → group ID.
  final Map<String, String> seriesGroupIds;

  final int totalMatched;

  @override
  Widget build(BuildContext context) {
    final seriesCount = seriesMatches.length;
    final sortedTitles =
        seriesMatches.keys.toList()
          ..sort((a, b) => seriesMatches[b]!.compareTo(seriesMatches[a]!));

    return AlertDialog(
      title: const Text('Kacheln sortieren'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$totalMatched Karten zu $seriesCount '
              '${seriesCount == 1 ? 'Kachel' : 'Kacheln'} sortiert.',
              style: const TextStyle(
                fontFamily: 'Nunito',
                fontSize: 14,
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 300),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: sortedTitles.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final title = sortedTitles[index];
                  final count = seriesMatches[title]!;
                  final groupId = seriesGroupIds[title]!;
                  return ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(
                      Icons.auto_stories_rounded,
                      size: 20,
                      color: AppColors.primary,
                    ),
                    title: Text(
                      title,
                      style: const TextStyle(
                        fontFamily: 'Nunito',
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                    subtitle: Text(
                      '$count ${count == 1 ? 'Karte' : 'Karten'}',
                      style: const TextStyle(
                        fontFamily: 'Nunito',
                        fontSize: 12,
                        color: AppColors.textSecondary,
                      ),
                    ),
                    trailing: const Icon(
                      Icons.chevron_right_rounded,
                      color: AppColors.textSecondary,
                    ),
                    onTap: () {
                      final router = GoRouter.of(context);
                      Navigator.of(context).pop();
                      unawaited(router.push(AppRoutes.parentTileEdit(groupId)));
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Fertig'),
        ),
      ],
    );
  }
}
