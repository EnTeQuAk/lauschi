import 'package:flutter/material.dart';
import 'package:lauschi/core/theme/app_theme.dart';

/// Header with back button, title, and optional NFC pair action.
class TileGroupHeader extends StatelessWidget {
  const TileGroupHeader({
    required this.title,
    required this.onBack,
    super.key,
    this.onNfcPair,
  });

  final String title;
  final VoidCallback onBack;
  final VoidCallback? onNfcPair;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.lg,
        AppSpacing.screenH,
        AppSpacing.sm,
      ),
      child: Row(
        children: [
          SizedBox(
            width: 72,
            height: 72,
            child: Semantics(
              label: 'Zurück',
              button: true,
              child: Material(
                color: AppColors.surfaceDim,
                shape: const CircleBorder(),
                child: InkWell(
                  key: const Key('back_button'),
                  customBorder: const CircleBorder(),
                  onTap: onBack,
                  child: const Icon(
                    Icons.chevron_left_rounded,
                    size: 48,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: 'Nunito',
                fontSize: 26,
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary,
                letterSpacing: -0.3,
              ),
            ),
          ),
          if (onNfcPair != null)
            IconButton(
              key: const Key('nfc_pair_button'),
              onPressed: onNfcPair,
              icon: const Icon(Icons.nfc_rounded),
              iconSize: 22,
              style: IconButton.styleFrom(
                minimumSize: const Size(44, 44),
                foregroundColor: AppColors.textSecondary,
              ),
              tooltip: 'NFC-Tag verknüpfen',
            ),
        ],
      ),
    );
  }
}
