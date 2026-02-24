import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lauschi/core/auth/pin_service.dart';
import 'package:lauschi/core/catalog/catalog_service.dart';
import 'package:lauschi/core/database/group_repository.dart';
import 'package:lauschi/core/router/app_router.dart';
import 'package:lauschi/core/settings/debug_settings.dart';
import 'package:lauschi/core/spotify/spotify_auth_provider.dart';
import 'package:lauschi/core/theme/app_theme.dart';

String _catalogSubtitle(WidgetRef ref) {
  final catalog = ref.watch(catalogServiceProvider).value;
  if (catalog == null) return 'Serien und Hörspiele durchstöbern';
  final count = catalog.all.where((s) => s.hasCuratedAlbums).length;
  return '$count Serien + ARD Audiothek';
}

/// Parent mode dashboard — editorial settings UI behind PIN gate.
///
/// Cooler stone surfaces, standard navigation, text labels.
class ParentDashboardScreen extends ConsumerWidget {
  const ParentDashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(spotifyAuthProvider);
    final groupsAsync = ref.watch(allGroupsProvider);
    final groupCount =
        groupsAsync.whenOrNull(data: (groups) => groups.length) ?? 0;
    final nfcEnabled =
        ref
            .watch(debugSettingsProvider)
            .whenOrNull(data: (s) => s.nfcEnabled) ??
        false;

    return Scaffold(
      backgroundColor: AppColors.parentBackground,
      appBar: AppBar(
        backgroundColor: AppColors.parentBackground,
        title: const Text('Einstellungen'),
        leading: IconButton(
          onPressed: () {
            ref.read(parentAuthProvider.notifier).deauthenticate();
            context.go(AppRoutes.kidHome);
          },
          icon: const Icon(Icons.close_rounded),
        ),
      ),
      body: ListView(
        children: [
          // Sammlung section
          const _SectionHeader(title: 'Sammlung'),
          _SettingsTile(
            icon: Icons.library_music_rounded,
            title:
                groupCount > 0
                    ? '$groupCount Serien verwalten'
                    : 'Serien verwalten',
            onTap: () => context.push(AppRoutes.parentManageCards),
          ),
          const Divider(indent: 56),
          _SettingsTile(
            icon: Icons.add_rounded,
            title: 'Hörspiel hinzufügen',
            subtitle: _catalogSubtitle(ref),
            onTap: () => context.push(AppRoutes.parentCatalog),
          ),
          const Divider(indent: 56),
          _SettingsTile(
            icon: Icons.explore_rounded,
            title: 'Entdecken',
            subtitle: 'Kostenlose Hörspiele der ARD Audiothek',
            onTap: () => context.push(AppRoutes.parentDiscover),
          ),

          const SizedBox(height: AppSpacing.lg),

          // Series section
          const _SectionHeader(title: 'Serien'),
          _SettingsTile(
            icon: Icons.layers_rounded,
            title: 'Serien verwalten',
            subtitle: 'Yakari, Bibi Blocksberg und mehr',
            onTap: () => context.push(AppRoutes.parentManageGroups),
          ),

          const SizedBox(height: AppSpacing.lg),

          // Streaming section
          const _SectionHeader(title: 'Streaming'),
          _SettingsTile(
            icon: Icons.music_note_rounded,
            title: 'Spotify',
            subtitle:
                authState is AuthAuthenticated
                    ? 'Verbunden — tippen zum Trennen'
                    : 'Nicht verbunden',
            trailing:
                authState is AuthAuthenticated
                    ? const Icon(Icons.check_circle, color: AppColors.success)
                    : null,
            onTap: () {
              if (authState is AuthAuthenticated) {
                _confirmSpotifyDisconnect(context, ref);
              } else {
                unawaited(
                  ref.read(spotifyAuthProvider.notifier).login(),
                );
              }
            },
          ),

          const SizedBox(height: AppSpacing.lg),

          // Einstellungen section
          const _SectionHeader(title: 'Einstellungen'),
          _SettingsTile(
            icon: Icons.lock_rounded,
            title: 'PIN ändern',
            onTap: () => unawaited(context.push(AppRoutes.pinChange)),
          ),
          // NFC tags — only visible when enabled in settings
          if (nfcEnabled) ...[
            const Divider(indent: 56),
            _SettingsTile(
              icon: Icons.nfc_rounded,
              title: 'NFC-Tags',
              subtitle: 'Tags mit Hörspielen verknüpfen',
              onTap: () => context.push(AppRoutes.parentNfcTags),
            ),
          ],
          const Divider(indent: 56),
          _SettingsTile(
            icon: Icons.info_outline_rounded,
            title: 'Über lauschi',
            subtitle: 'Einstellungen & Version',
            leadingWidget: Padding(
              padding: const EdgeInsets.only(right: AppSpacing.md),
              child: ClipRRect(
                borderRadius: const BorderRadius.all(Radius.circular(8)),
                child: Image.asset(
                  'assets/images/branding/lauschi-logo.png',
                  width: 40,
                  height: 40,
                ),
              ),
            ),
            onTap: () => context.push(AppRoutes.parentSettings),
          ),
        ],
      ),
    );
  }
}

/// Disconnect Spotify without wiping the database.
/// Re-authenticates with a potentially different account while keeping
/// all series, cards, and settings intact.
void _confirmSpotifyDisconnect(BuildContext context, WidgetRef ref) {
  unawaited(
    showDialog<void>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('Spotify trennen?'),
            content: const Text(
              'Deine Serien und Einstellungen bleiben erhalten. '
              'Du kannst dich danach mit einem anderen Konto verbinden.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Abbrechen'),
              ),
              FilledButton(
                onPressed: () {
                  Navigator.of(ctx).pop();
                  unawaited(
                    ref.read(spotifyAuthProvider.notifier).logout(),
                  );
                },
                child: const Text('Trennen'),
              ),
            ],
          ),
    ),
  );
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.screenH,
        AppSpacing.md,
        AppSpacing.screenH,
        AppSpacing.xs,
      ),
      child: Text(
        title.toUpperCase(),
        style: const TextStyle(
          fontFamily: 'Nunito',
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
          color: AppColors.textSecondary,
        ),
      ),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  const _SettingsTile({
    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.trailing,
    this.leadingWidget,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final Widget? leadingWidget;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: leadingWidget ?? Icon(icon, color: AppColors.textSecondary),
      title: Text(
        title,
        style: const TextStyle(
          fontFamily: 'Nunito',
          fontWeight: FontWeight.w600,
          fontSize: 15,
        ),
      ),
      subtitle:
          subtitle != null
              ? Text(
                subtitle!,
                style: const TextStyle(
                  fontFamily: 'Nunito',
                  fontSize: 13,
                  color: AppColors.textSecondary,
                ),
              )
              : null,
      trailing: trailing ?? const Icon(Icons.chevron_right_rounded),
      onTap: onTap,
      tileColor: AppColors.parentSurface,
    );
  }
}
