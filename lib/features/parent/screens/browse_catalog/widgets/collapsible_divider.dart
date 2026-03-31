import 'package:flutter/material.dart';
import 'package:lauschi/core/catalog/catalog_service.dart';
import 'package:lauschi/core/theme/app_theme.dart';

/// Divider between curated hero cards and individual search results.
/// Allows expanding/collapsing the individual results section.
class CollapsibleDivider extends StatelessWidget {
  const CollapsibleDivider({
    required this.matchingCount,
    required this.heroes,
    required this.isExpanded,
    required this.onToggle,
    super.key,
  });

  final int matchingCount;
  final List<CatalogSeries> heroes;
  final bool isExpanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final label =
        heroes.length == 1
            ? '$matchingCount Einzelfolgen · In ${heroes.first.title} enthalten'
            : '$matchingCount Einzelfolgen · In den Empfehlungen enthalten';

    return Semantics(
      button: true,
      expanded: isExpanded,
      onTapHint:
          isExpanded
              ? 'Einzelne Ergebnisse ausblenden'
              : 'Einzelne Ergebnisse anzeigen',
      child: InkWell(
        onTap: onToggle,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.screenH,
            vertical: AppSpacing.md,
          ),
          child: Column(
            children: [
              const Divider(height: 1),
              const SizedBox(height: AppSpacing.sm),
              Text(
                label,
                style: const TextStyle(
                  fontFamily: 'Nunito',
                  fontSize: 12,
                  color: AppColors.textTertiary,
                ),
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    isExpanded
                        ? 'Einzelne Ergebnisse ausblenden'
                        : 'Einzelne Ergebnisse anzeigen',
                    style: const TextStyle(
                      fontFamily: 'Nunito',
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppColors.primary,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    isExpanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 18,
                    color: AppColors.primary,
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              const Divider(height: 1),
            ],
          ),
        ),
      ),
    );
  }
}
