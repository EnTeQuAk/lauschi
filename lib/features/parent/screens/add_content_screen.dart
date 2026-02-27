import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lauschi/core/providers/provider_registry.dart';
import 'package:lauschi/core/providers/provider_type.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/parent/screens/browse_catalog_screen.dart';
import 'package:lauschi/features/parent/screens/discover_screen.dart';

/// Tabbed screen for adding content from any enabled provider.
///
/// Each tab renders the provider's browse experience (embedded, no Scaffold).
/// The available tabs are driven by the [providerRegistryProvider].
class AddContentScreen extends ConsumerWidget {
  const AddContentScreen({super.key, this.initialTab});

  /// Which provider tab to show initially. Defaults to the first tab.
  final ProviderType? initialTab;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final providers = ref.watch(providerRegistryProvider);

    // Determine initial tab index.
    final initialIndex =
        initialTab != null
            ? providers
                .indexWhere((p) => p.type == initialTab)
                .clamp(0, providers.length - 1)
            : 0;

    return DefaultTabController(
      length: providers.length,
      initialIndex: initialIndex,
      child: Scaffold(
        backgroundColor: AppColors.parentBackground,
        appBar: AppBar(
          backgroundColor: AppColors.parentBackground,
          title: const Text('Inhalte hinzufügen'),
          bottom: TabBar(
            isScrollable: providers.length > 3,
            tabs: [
              for (final p in providers)
                Tab(
                  icon: Icon(p.type.icon, size: 18),
                  text: p.type.displayName,
                ),
            ],
            labelColor: AppColors.textPrimary,
            unselectedLabelColor: AppColors.textSecondary,
            indicatorColor: AppColors.primary,
            labelStyle: const TextStyle(
              fontFamily: 'Nunito',
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
            unselectedLabelStyle: const TextStyle(
              fontFamily: 'Nunito',
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        body: TabBarView(
          children: [
            for (final p in providers) _tabBody(p.type),
          ],
        ),
      ),
    );
  }

  Widget _tabBody(ProviderType type) => switch (type) {
    ProviderType.ardAudiothek => const DiscoverScreen(embedded: true),
    ProviderType.spotify => const BrowseCatalogScreen(embedded: true),
    // Future providers: add their embedded browse widgets here.
    ProviderType.appleMusic => _ComingSoon(type: type),
    ProviderType.tidal => _ComingSoon(type: type),
  };
}

class _ComingSoon extends StatelessWidget {
  const _ComingSoon({required this.type});

  final ProviderType type;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppColors.parentBackground,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(type.icon, size: 48, color: AppColors.textSecondary),
            const SizedBox(height: AppSpacing.md),
            Text(
              '${type.displayName} kommt bald',
              style: const TextStyle(
                fontFamily: 'Nunito',
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: AppColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
