import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lauschi/core/auth/pin_service.dart';
import 'package:lauschi/core/database/tile_repository.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/providers/provider_auth.dart';
import 'package:lauschi/core/providers/provider_registry.dart';
import 'package:lauschi/core/providers/provider_type.dart';
import 'package:lauschi/core/router/app_router.dart';
import 'package:lauschi/core/settings/debug_settings.dart';
import 'package:lauschi/core/theme/app_theme.dart';

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
          // ── Sammlung ─────────────────────────────────────────────────
          const _SectionHeader(title: 'Sammlung'),
          _SettingsTile(
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
          const _SectionHeader(title: 'Einstellungen'),
          _SettingsTile(
            icon: Icons.lock_rounded,
            title: 'PIN ändern',
            onTap: () => unawaited(context.push(AppRoutes.pinChange)),
          ),

          // Disconnect tiles for authenticated providers
          for (final provider in providers.where((p) => p.canDisconnect))
            ...[
              const Divider(indent: 56),
              _SettingsTile(
                icon: Icons.logout_rounded,
                title: '${provider.type.displayName} trennen',
                subtitle: 'Konto wechseln (Kacheln bleiben erhalten)',
                onTap: () => _confirmDisconnect(context, ref, provider),
              ),
            ],

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

  List<Widget> _providerTile(
    BuildContext context,
    WidgetRef ref,
    ProviderInfo provider,
  ) {
    final isAuthenticated =
        provider.authState == ProviderAuthState.authenticated;

    final subtitle = switch (provider.type) {
      ProviderType.ardAudiothek => 'Kostenlose Hörspiele und Podcasts',
      _ when isAuthenticated => 'Verbunden',
      _ => 'Nicht verbunden',
    };

    return [
      const Divider(indent: 56),
      _SettingsTile(
        icon: provider.type.icon,
        title: provider.type.displayName,
        subtitle: subtitle,
        trailing:
            isAuthenticated && provider.auth.requiresAuth
                ? const Icon(
                  Icons.check_circle,
                  color: AppColors.success,
                  size: 18,
                )
                : null,
        onTap: () => _onProviderTap(context, ref, provider),
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
      // Not authenticated -- start auth flow
      Log.info(_tag, 'Connecting provider', data: {
        'provider': provider.type.value,
      });
      unawaited(provider.auth.authenticate());
      return;
    }

    // Navigate to provider's browse screen.
    // TODO(#multi-provider): unify into tabbed add-content screen in phase 3.
    switch (provider.type) {
      case ProviderType.spotify:
        unawaited(context.push(AppRoutes.parentCatalog));
      case ProviderType.ardAudiothek:
        unawaited(context.push(AppRoutes.parentDiscover));
      case ProviderType.appleMusic:
      case ProviderType.tidal:
        break; // disabled, shouldn't reach here
    }
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
