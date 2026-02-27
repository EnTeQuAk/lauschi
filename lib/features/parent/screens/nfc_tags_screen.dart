import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lauschi/core/database/app_database.dart' as db;
import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/nfc/nfc_service.dart';
import 'package:lauschi/core/theme/app_theme.dart';

const _tag = 'NfcTagsScreen';

/// NFC tag management — list paired tags, delete mappings.
///
/// Pairing happens contextually from group/card screens, not here.
/// This screen is for overview and cleanup.
class NfcTagsScreen extends ConsumerWidget {
  const NfcTagsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nfc = ref.watch(nfcServiceProvider);

    return Scaffold(
      backgroundColor: AppColors.parentBackground,
      appBar: AppBar(
        backgroundColor: AppColors.parentBackground,
        title: const Text('NFC-Tags'),
      ),
      body: StreamBuilder<List<db.NfcTag>>(
        stream: nfc.watchAll(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          final tags = snapshot.data ?? [];

          if (tags.isEmpty) {
            return const _EmptyState();
          }

          return ListView.builder(
            itemCount: tags.length,
            padding: const EdgeInsets.only(bottom: AppSpacing.xxl),
            itemBuilder: (context, index) {
              final tag = tags[index];
              return _TagTile(
                tag: tag,
                onDelete: () async {
                  Log.info(_tag, 'NFC tag deleted', data: {
                    'tagUid': tag.tagUid,
                    'targetType': tag.targetType,
                  });
                  await nfc.deleteMapping(tag.tagUid);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context)
                      ..clearSnackBars()
                      ..showSnackBar(
                        SnackBar(
                          content: Text(
                            '${tag.label ?? tag.tagUid} entfernt',
                          ),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                  }
                },
              );
            },
          );
        },
      ),
    );
  }
}

class _TagTile extends StatelessWidget {
  const _TagTile({required this.tag, required this.onDelete});

  final db.NfcTag tag;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final icon =
        tag.targetType == 'group'
            ? Icons.auto_stories_rounded
            : Icons.album_rounded;

    return ListTile(
      tileColor: AppColors.parentSurface,
      leading: const Icon(Icons.nfc_rounded, color: AppColors.primary),
      title: Text(
        tag.label ?? 'Tag ${tag.tagUid.substring(0, 8)}…',
        style: const TextStyle(
          fontFamily: 'Nunito',
          fontWeight: FontWeight.w600,
          fontSize: 15,
        ),
      ),
      subtitle: Row(
        children: [
          Icon(icon, size: 14, color: AppColors.textSecondary),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              '${tag.targetType == 'group' ? 'Kachel' : 'Karte'} · ${tag.tagUid}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: 'Nunito',
                fontSize: 12,
                color: AppColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
      trailing: IconButton(
        onPressed: onDelete,
        icon: const Icon(Icons.delete_outline_rounded),
        color: AppColors.error,
        tooltip: 'Entfernen',
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(AppSpacing.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.nfc_rounded,
              size: 64,
              color: AppColors.primarySoft,
            ),
            SizedBox(height: AppSpacing.lg),
            Text(
              'Noch keine NFC-Tags',
              style: TextStyle(
                fontFamily: 'Nunito',
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
            ),
            SizedBox(height: AppSpacing.sm),
            Text(
              'Öffne eine Kachel und tippe '
              '„NFC-Tag verknüpfen", um einen Tag zuzuweisen.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'Nunito',
                fontSize: 14,
                color: AppColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
