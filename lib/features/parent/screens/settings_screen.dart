import 'dart:async' show unawaited;

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lauschi/core/app_version.dart';
import 'package:lauschi/core/feature_flags.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/settings/debug_settings.dart';
import 'package:lauschi/core/settings/kid_settings.dart';
import 'package:lauschi/core/spotify/spotify_session.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/onboarding/screens/onboarding_provider.dart';
import 'package:lauschi/features/parent/widgets/parent_section_header.dart';
import 'package:lauschi/features/parent/widgets/settings/ard_attribution.dart';
import 'package:lauschi/features/parent/widgets/settings/provider_row.dart';
import 'package:lauschi/features/parent/widgets/settings/support_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _buildFlavour = kDebugMode ? 'debug' : 'release';

const _tag = 'SettingsScreen';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  // Track whether any setting changed this session — used to show the
  // "Neustart erforderlich" banner.
  bool _changed = false;

  @override
  Widget build(BuildContext context) {
    final settingsAsync = ref.watch(debugSettingsProvider);

    return Scaffold(
      backgroundColor: AppColors.parentBackground,
      appBar: AppBar(
        backgroundColor: AppColors.parentBackground,
        title: const Text('Über lauschi'),
      ),
      body: settingsAsync.when(
        data: (settings) => _buildBody(context, settings),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Fehler: $e')),
      ),
    );
  }

  Widget _buildBody(BuildContext context, DebugSettings settings) {
    return ListView(
      children: [
        // ── Restart banner ──────────────────────────────────────────────────
        if (_changed)
          _RestartBanner(onDismiss: () => setState(() => _changed = false)),

        // ── Mascot ──────────────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
          child: Center(
            child: Image.asset(
              'assets/images/branding/lauschi-mascot.png',
              width: 120,
              height: 120,
            ),
          ),
        ),

        // ── App version ──────────────────────────────────────────────────────
        const ParentSectionHeader(title: 'App'),
        _InfoTile(
          icon: Icons.info_outline_rounded,
          title: 'Version',
          value:
              '${ref.watch(appVersionProvider).value ?? '…'}'
              ' ($_buildFlavour)',
        ),
        ListTile(
          key: const Key('open_source_licenses'),
          tileColor: AppColors.parentSurface,
          leading: const Icon(
            Icons.description_outlined,
            color: AppColors.textSecondary,
          ),
          title: const Text(
            'Open-Source-Lizenzen',
            style: TextStyle(
              fontFamily: 'Nunito',
              fontWeight: FontWeight.w600,
              fontSize: 15,
            ),
          ),
          trailing: const Icon(
            Icons.chevron_right_rounded,
            color: AppColors.textSecondary,
          ),
          onTap:
              () => showLicensePage(
                context: context,
                applicationName: 'lauschi',
                applicationVersion:
                    '${ref.watch(appVersionProvider).value ?? '…'}'
                    ' ($_buildFlavour)',
                applicationIcon: Padding(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  child: Image.asset(
                    'assets/images/branding/lauschi-mascot.png',
                    width: 64,
                    height: 64,
                  ),
                ),
              ),
        ),

        const SizedBox(height: AppSpacing.lg),

        // ── Kindansicht ──────────────────────────────────────────────────────
        const ParentSectionHeader(title: 'Kindansicht'),
        _SwitchTile(
          icon: Icons.text_fields_rounded,
          title: 'Episodentitel anzeigen',
          subtitle: 'Titel neben Episodennummer auf Kacheln zeigen',
          value: ref.watch(showEpisodeTitlesProvider).value ?? false,
          onChanged:
              (_) => ref.read(showEpisodeTitlesProvider.notifier).toggle(),
        ),

        const SizedBox(height: AppSpacing.lg),

        // ── Providers ────────────────────────────────────────────────────────
        const ParentSectionHeader(title: 'Inhalte bereitgestellt von'),
        const ProviderRow(),
        const ArdAttribution(),

        const SizedBox(height: AppSpacing.lg),

        // ── Support ──────────────────────────────────────────────────────────
        const SupportCard(),

        // ── Sentry / Diagnostics (testers only) ────────────────────────────
        if (FeatureFlags.enableSentry) ...[
          const SizedBox(height: AppSpacing.lg),
          const ParentSectionHeader(title: 'Diagnose & Datenschutz'),
          _SwitchTile(
            icon: Icons.videocam_outlined,
            title: 'Session-Aufzeichnungen',
            subtitle:
                'Sentry zeichnet Bildschirminhalte zur Fehleranalyse auf. '
                '${settings.replayEnabled ? "Aktiv" : "Inaktiv"}.',
            value: settings.replayEnabled,
            onChanged: (v) async {
              if (v) {
                // Show consent dialog before enabling screen recording.
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder:
                      (ctx) => AlertDialog(
                        title: const Text('Fehlerdiagnose aktivieren?'),
                        content: const Text(
                          'Bei Fehlern wird eine anonymisierte '
                          'Bildschirmaufzeichnung erstellt und an Sentry '
                          '(EU-Server) gesendet. Texte und Bilder werden '
                          'standardmäßig maskiert.\n\n'
                          'Du kannst dies jederzeit wieder deaktivieren.',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx, false),
                            child: const Text('Abbrechen'),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(ctx, true),
                            child: const Text('Aktivieren'),
                          ),
                        ],
                      ),
                );
                if (confirmed != true || !mounted) return;
              }
              await _update(settings.copyWith(replayEnabled: v));
            },
          ),
          const Divider(indent: 56),
          _SwitchTile(
            icon: Icons.text_fields_rounded,
            title: 'Text anonymisieren',
            subtitle: 'Ersetzt alle Texte in Aufzeichnungen durch Blöcke.',
            value: settings.maskAllText,
            onChanged:
                settings.replayEnabled
                    ? (v) => _update(settings.copyWith(maskAllText: v))
                    : null,
          ),
          const Divider(indent: 56),
          _SwitchTile(
            icon: Icons.image_outlined,
            title: 'Bilder anonymisieren',
            subtitle: 'Ersetzt Album-Cover in Aufzeichnungen durch Blöcke.',
            value: settings.maskAllImages,
            onChanged:
                settings.replayEnabled
                    ? (v) => _update(settings.copyWith(maskAllImages: v))
                    : null,
          ),
        ],

        const SizedBox(height: AppSpacing.lg),

        // ── Spotify account (only when enabled) ──────────────────────────────
        if (FeatureFlags.enableSpotify) ...[
          const ParentSectionHeader(title: 'Spotify-Konto'),
          ListTile(
            key: const Key('logout_button'),
            tileColor: AppColors.parentSurface,
            leading: const Icon(
              Icons.logout_rounded,
              color: AppColors.error,
            ),
            title: const Text(
              'Abmelden',
              style: TextStyle(
                fontFamily: 'Nunito',
                fontWeight: FontWeight.w600,
                fontSize: 15,
                color: AppColors.error,
              ),
            ),
            subtitle: const Text(
              'Spotify-Verbindung trennen und zur Anmeldung zurückkehren.',
              style: TextStyle(
                fontFamily: 'Nunito',
                fontSize: 12,
                color: AppColors.textSecondary,
              ),
            ),
            onTap: () => _confirmLogout(context),
          ),
          const SizedBox(height: AppSpacing.lg),
        ],

        // ── Experimental ─────────────────────────────────────────────────────
        const ParentSectionHeader(title: 'Experimentell'),
        _SwitchTile(
          icon: Icons.nfc_rounded,
          title: 'NFC-Tags',
          subtitle:
              'Kacheln mit NFC-Tags verknüpfen. '
              'Kind hält Tag ans Gerät → Wiedergabe startet.',
          value: settings.nfcEnabled,
          onChanged: (v) => _update(settings.copyWith(nfcEnabled: v)),
        ),
      ],
    );
  }

  void _confirmLogout(BuildContext context) {
    unawaited(
      showDialog<void>(
        context: context,
        builder:
            (ctx) => AlertDialog(
              title: const Text('Von Spotify abmelden?'),
              content: const Text(
                'Du wirst zur Anmeldung weitergeleitet. '
                'Deine Karten und Kacheln bleiben erhalten.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Abbrechen'),
                ),
                FilledButton(
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    unawaited(_performLogout());
                  },
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.error,
                  ),
                  child: const Text('Abmelden'),
                ),
              ],
            ),
      ),
    );
  }

  Future<void> _performLogout() async {
    Log.info(_tag, 'Performing logout');

    // Session handles everything: bridge teardown, token cleanup.
    await ref.read(spotifySessionProvider.notifier).logout();

    // Reset onboarding so the router redirects to the login flow.
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('onboarding_complete', false);
    unawaited(ref.read(onboardingCompleteProvider.notifier).checkAsync());
  }

  Future<void> _update(DebugSettings updated) async {
    Log.info(
      _tag,
      'Settings updated',
      data: {
        'replayEnabled': '${updated.replayEnabled}',
        'maskAllText': '${updated.maskAllText}',
        'maskAllImages': '${updated.maskAllImages}',
        'nfcEnabled': '${updated.nfcEnabled}',
      },
    );
    await ref.read(debugSettingsProvider.notifier).save(updated);
    if (mounted) setState(() => _changed = true);
  }
}

// ── Inline widgets (kept here, all <50 lines) ─────────────────────────

class _RestartBanner extends StatelessWidget {
  const _RestartBanner({required this.onDismiss});
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.warning.withValues(alpha: 0.15),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.screenH,
          vertical: AppSpacing.sm,
        ),
        child: Row(
          children: [
            const Icon(
              Icons.restart_alt_rounded,
              size: 18,
              color: AppColors.warning,
            ),
            const SizedBox(width: AppSpacing.sm),
            const Expanded(
              child: Text(
                'Neustart erforderlich, um Änderungen zu übernehmen.',
                style: TextStyle(
                  fontFamily: 'Nunito',
                  fontSize: 13,
                  color: AppColors.warning,
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close_rounded, size: 18),
              color: AppColors.warning,
              onPressed: onDismiss,
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoTile extends StatelessWidget {
  const _InfoTile({
    required this.icon,
    required this.title,
    required this.value,
  });

  final IconData icon;
  final String title;
  final String value;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      tileColor: AppColors.parentSurface,
      leading: Icon(icon, color: AppColors.textSecondary),
      title: Text(
        title,
        style: const TextStyle(
          fontFamily: 'Nunito',
          fontWeight: FontWeight.w600,
          fontSize: 15,
        ),
      ),
      trailing: Text(
        value,
        style: const TextStyle(
          fontFamily: 'Nunito',
          fontSize: 13,
          color: AppColors.textSecondary,
        ),
      ),
    );
  }
}

class _SwitchTile extends StatelessWidget {
  const _SwitchTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      tileColor: AppColors.parentSurface,
      secondary: Icon(
        icon,
        color: onChanged != null ? AppColors.textSecondary : AppColors.textHint,
      ),
      title: Text(
        title,
        style: TextStyle(
          fontFamily: 'Nunito',
          fontWeight: FontWeight.w600,
          fontSize: 15,
          color: onChanged != null ? null : AppColors.textHint,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: const TextStyle(
          fontFamily: 'Nunito',
          fontSize: 12,
          color: AppColors.textSecondary,
        ),
      ),
      value: value,
      onChanged: onChanged,
    );
  }
}
