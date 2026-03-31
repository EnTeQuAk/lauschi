import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lauschi/core/auth/pin_service.dart';
import 'package:lauschi/core/database/content_importer.dart';
import 'package:lauschi/core/database/tile_repository.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/providers/provider_auth.dart';
import 'package:lauschi/core/providers/provider_registry.dart';
import 'package:lauschi/core/providers/provider_type.dart';
import 'package:lauschi/core/router/app_router.dart';
import 'package:lauschi/core/settings/debug_settings.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/parent/widgets/parent_section_header.dart';

const _tag = 'ParentDashboard';

/// Parent mode dashboard -- editorial settings UI behind PIN gate.
class ParentDashboardScreen extends ConsumerWidget {
  const ParentDashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final providers = ref.watch(providerRegistryProvider);
    final tilesAsync = ref.watch(allTilesProvider);
    final tileCount = tilesAsync.whenOrNull(data: (tiles) => tiles.length) ?? 0;
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
          key: const Key('exit_parent_mode'),
          onPressed: () {
            Log.info(_tag, 'Exiting parent mode');
            ref.read(parentAuthProvider.notifier).deauthenticate();
            context.go(AppRoutes.kidHome);
          },
          icon: const Icon(Icons.close_rounded),
        ),
      ),
      body: ListView(
        children: [
          if (ref.watch(contentImporterProvider)
              case final ImportRunning running)
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.screenH,
                vertical: AppSpacing.sm,
              ),
              color: AppColors.primary.withValues(alpha: 0.1),
              child: Row(
                children: [
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Text(
                    'Importiere ${running.showTitle}…',
                    style: const TextStyle(
                      fontFamily: 'Nunito',
                      fontSize: 13,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          // ── Sammlung ─────────────────────────────────────────────────
          const ParentSectionHeader(title: 'Sammlung'),
          _SettingsTile(
            key: const Key('manage_tiles'),
            icon: Icons.library_music_rounded,
            title:
                tileCount > 0
                    ? '$tileCount Kacheln verwalten'
                    : 'Kacheln verwalten',
            subtitle: 'Kacheln verwalten und sortieren',
            onTap: () => context.push(AppRoutes.parentManageTiles),
          ),

          // Provider tiles -- driven by registry
          for (final provider in providers)
            ..._providerTile(context, ref, provider),

          const SizedBox(height: AppSpacing.lg),

          // ── Einstellungen ────────────────────────────────────────────
          const ParentSectionHeader(title: 'Einstellungen'),
          _SettingsTile(
            key: const Key('change_pin'),
            icon: Icons.lock_rounded,
            title: 'PIN ändern',
            onTap: () => unawaited(context.push(AppRoutes.pinChange)),
          ),

          // Disconnect tiles for authenticated providers
          for (final provider in providers.where((p) => p.canDisconnect)) ...[
            const Divider(indent: 56),
            _SettingsTile(
              key: Key('disconnect_${provider.type.name}'),
              icon: Icons.logout_rounded,
              title: '${provider.type.displayName} trennen',
              subtitle: 'Konto wechseln (Kacheln bleiben erhalten)',
              onTap: () => _confirmDisconnect(context, ref, provider),
            ),
          ],

          if (nfcEnabled) ...[
            const Divider(indent: 56),
            _SettingsTile(
              key: const Key('nfc_tags'),
              icon: Icons.nfc_rounded,
              title: 'NFC-Tags',
              subtitle: 'Tags mit Hörspielen verknüpfen',
              onTap: () => context.push(AppRoutes.parentNfcTags),
            ),
          ],
          const Divider(indent: 56),
          ListTile(
            key: const Key('about_settings'),
            leading: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: Image.asset(
                'assets/images/branding/lauschi-logo.png',
                width: 24,
                height: 24,
              ),
            ),
            title: const Text(
              'Über lauschi',
              style: TextStyle(
                fontFamily: 'Nunito',
                fontWeight: FontWeight.w600,
                fontSize: 15,
              ),
            ),
            subtitle: const Text(
              'Einstellungen & Version',
              style: TextStyle(
                fontFamily: 'Nunito',
                fontSize: 13,
                color: AppColors.textSecondary,
              ),
            ),
            trailing: const Icon(Icons.chevron_right_rounded),
            tileColor: AppColors.parentSurface,
            onTap: () => context.push(AppRoutes.parentSettings),
          ),
        ],
      ),
    );
  }

  List<Widget> _providerTile(
    BuildContext context,
    WidgetRef ref,
    ProviderInfo provider,
  ) {
    final authState = provider.authState;
    final isAuthenticated = authState == ProviderAuthState.authenticated;
    final isLoading = authState == ProviderAuthState.loading;

    final subtitle = switch (provider.type) {
      ProviderType.ardAudiothek => 'Kostenlose Hörspiele und Podcasts',
      _ when isAuthenticated => 'Verbunden',
      _ when isLoading => 'Verbinde…',
      _ => 'Nicht verbunden',
    };

    final trailing =
        isAuthenticated && provider.auth.requiresAuth
            ? const Icon(Icons.check_circle, color: AppColors.success, size: 18)
            : isLoading
            ? SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: provider.type.color,
              ),
            )
            : null;

    return [
      const Divider(indent: 56),
      _SettingsTile(
        key: Key('provider_${provider.type.name}'),
        icon: provider.type.icon,
        title: provider.type.displayName,
        subtitle: subtitle,
        trailing: trailing,
        onTap: isLoading ? null : () => _onProviderTap(context, ref, provider),
      ),
    ];
  }

  void _onProviderTap(
    BuildContext context,
    WidgetRef ref,
    ProviderInfo provider,
  ) {
    final isAuthenticated =
        provider.authState == ProviderAuthState.authenticated;

    if (!isAuthenticated && provider.auth.requiresAuth) {
      Log.info(
        _tag,
        'Connecting provider',
        data: {
          'provider': provider.type.value,
        },
      );
      unawaited(provider.auth.authenticate());
      return;
    }

    // Navigate to the tabbed add-content screen, opening the tapped tab.
    unawaited(context.push(AppRoutes.parentAddContent, extra: provider.type));
  }
}

/// Disconnect a provider after confirmation.
void _confirmDisconnect(
  BuildContext context,
  WidgetRef ref,
  ProviderInfo provider,
) {
  unawaited(
    showDialog<void>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: Text('${provider.type.displayName} trennen?'),
            content: const Text(
              'Deine Kacheln und Einstellungen bleiben erhalten. '
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
                  Log.info(
                    _tag,
                    'Provider disconnected',
                    data: {'provider': provider.type.value},
                  );
                  unawaited(provider.auth.logout());
                },
                child: const Text('Trennen'),
              ),
            ],
          ),
    ),
  );
}

class _SettingsTile extends StatelessWidget {
  const _SettingsTile({
    required this.icon,
    required this.title,
    this.onTap,
    this.subtitle,
    this.trailing,
    super.key,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: AppColors.textSecondary),
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
