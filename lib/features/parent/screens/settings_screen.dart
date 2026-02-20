import 'dart:async' show unawaited;

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lauschi/core/settings/debug_settings.dart';
import 'package:lauschi/core/spotify/spotify_auth_provider.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/onboarding/screens/onboarding_provider.dart';
import 'package:lauschi/features/player/player_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Version is injected at build time via --dart-define=APP_VERSION.
// Falls back to pubspec version for local dev.
const _appVersion = String.fromEnvironment(
  'APP_VERSION',
  defaultValue: '0.1.0',
);
const _buildFlavour = kDebugMode ? 'debug' : 'release';

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
        const _SectionHeader(title: 'App'),
        const _InfoTile(
          icon: Icons.info_outline_rounded,
          title: 'Version',
          value: '$_appVersion ($_buildFlavour)',
        ),
        const _InfoTile(
          icon: Icons.music_note_rounded,
          title: 'Musik',
          value: 'Powered by Spotify',
        ),

        const SizedBox(height: AppSpacing.lg),

        // ── Sentry / Diagnostics ─────────────────────────────────────────────
        const _SectionHeader(title: 'Diagnose & Datenschutz'),
        _SwitchTile(
          icon: Icons.videocam_outlined,
          title: 'Session-Aufzeichnungen',
          subtitle:
              'Sentry zeichnet Bildschirminhalte zur Fehleranalyse auf. '
              'Standardmäßig aktiv in Debug-Builds.',
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

        const SizedBox(height: AppSpacing.lg),

        // ── Spotify account ──────────────────────────────────────────────────
        const _SectionHeader(title: 'Spotify-Konto'),
        ListTile(
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

        // ── Experimental ─────────────────────────────────────────────────────
        const _SectionHeader(title: 'Experimentell'),
        _SwitchTile(
          icon: Icons.nfc_rounded,
          title: 'NFC-Tags',
          subtitle:
              'Hörspiele und Serien mit NFC-Tags verknüpfen. '
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
                'Deine Karten und Serien bleiben erhalten.',
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
    // Disconnect the player bridge.
    final bridge = ref.read(spotifyPlayerBridgeProvider);
    await bridge.dispose();

    // Invalidate the bridge provider so a fresh instance is created on
    // next login. Without this, the disposed bridge (closed StreamController,
    // stale WebViewController) would be reused.
    ref.invalidate(spotifyPlayerBridgeProvider);

    // Clear tokens.
    await ref.read(spotifyAuthProvider.notifier).logout();

    // Reset onboarding so the router redirects to the login flow.
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('onboarding_complete', false);
    unawaited(ref.read(onboardingCompleteProvider.notifier).checkAsync());
  }

  Future<void> _update(DebugSettings updated) async {
    await ref.read(debugSettingsProvider.notifier).save(updated);
    if (mounted) setState(() => _changed = true);
  }
}

// ── Supporting widgets ──────────────────────────────────────────────────────

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
