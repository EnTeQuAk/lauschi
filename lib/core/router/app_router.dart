import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lauschi/core/auth/pin_service.dart';
import 'package:lauschi/features/cards/screens/group_detail_screen.dart';
import 'package:lauschi/features/cards/screens/kid_home_screen.dart';
import 'package:lauschi/features/onboarding/screens/onboarding_provider.dart';
import 'package:lauschi/features/onboarding/screens/onboarding_screen.dart';
import 'package:lauschi/features/parent/screens/add_card_screen.dart';
import 'package:lauschi/features/parent/screens/browse_catalog_screen.dart';
import 'package:lauschi/features/parent/screens/group_edit_screen.dart';
import 'package:lauschi/features/parent/screens/manage_cards_screen.dart';
import 'package:lauschi/features/parent/screens/manage_groups_screen.dart';
import 'package:lauschi/features/parent/screens/nfc_tags_screen.dart';
import 'package:lauschi/features/parent/screens/parent_dashboard_screen.dart';
import 'package:lauschi/features/parent/screens/pin_screen.dart';
import 'package:lauschi/features/parent/screens/settings_screen.dart';
import 'package:lauschi/features/player/screens/player_screen.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'app_router.g.dart';

// Route paths — single source of truth
abstract final class AppRoutes {
  // Onboarding
  static const onboarding = '/onboarding';

  // Kid mode (root)
  static const kidHome = '/';
  static const player = '/player';

  // Group/series drill-down
  static String groupDetail(String groupId) => '/group/$groupId';

  // Parent mode (PIN-gated)
  static const parentDashboard = '/parent';
  static const parentManageCards = '/parent/cards';
  static const parentAddCard = '/parent/add-card';
  static String parentAddCardToGroup(String groupId) =>
      '/parent/add-card?groupId=$groupId';
  static const parentManageGroups = '/parent/groups';
  static String parentGroupEdit(String groupId) => '/parent/groups/$groupId';
  static const parentSettings = '/parent/settings';
  static const parentNfcTags = '/parent/nfc-tags';
  static const parentCatalog = '/parent/catalog';
  static String parentCatalogSeries(String seriesId) =>
      '/parent/catalog/$seriesId';
  static const pinEntry = '/pin';
  static const pinChange = '/pin/change';
}

@Riverpod(keepAlive: true)
GoRouter appRouter(Ref ref) {
  // Re-evaluate redirects when auth or onboarding state changes.
  final refreshNotifier = _RouterRefreshNotifier();
  ref
    ..listen(onboardingCompleteProvider, (_, _) => refreshNotifier.notify())
    ..listen(parentAuthProvider, (_, _) => refreshNotifier.notify())
    ..onDispose(refreshNotifier.dispose);

  return GoRouter(
    initialLocation: AppRoutes.kidHome,
    debugLogDiagnostics: true,
    refreshListenable: refreshNotifier,
    redirect: (context, state) => _globalRedirect(ref, state),
    routes: [
      GoRoute(
        path: AppRoutes.onboarding,
        builder: (context, state) => const OnboardingScreen(),
      ),
      GoRoute(
        path: AppRoutes.kidHome,
        builder: (context, state) => const KidHomeScreen(),
        routes: [
          GoRoute(
            path: 'player',
            builder: (context, state) => const PlayerScreen(),
          ),
          GoRoute(
            path: 'group/:id',
            builder: (context, state) {
              final groupId = state.pathParameters['id']!;
              return GroupDetailScreen(groupId: groupId);
            },
          ),
        ],
      ),
      GoRoute(
        path: AppRoutes.pinEntry,
        builder: (context, state) => const PinScreen(),
      ),
      GoRoute(
        path: AppRoutes.pinChange,
        builder: (context, state) => const PinScreen(isSetup: true),
      ),
      GoRoute(
        path: AppRoutes.parentDashboard,
        builder: (context, state) => const ParentDashboardScreen(),
        routes: [
          GoRoute(
            path: 'cards',
            builder: (context, state) => const ManageCardsScreen(),
          ),
          GoRoute(
            path: 'add-card',
            builder:
                (context, state) => AddCardScreen(
                  autoAssignGroupId: state.uri.queryParameters['groupId'],
                ),
          ),
          GoRoute(
            path: 'groups',
            builder: (context, state) => const ManageGroupsScreen(),
            routes: [
              GoRoute(
                path: ':id',
                builder: (context, state) {
                  final groupId = state.pathParameters['id']!;
                  return GroupEditScreen(groupId: groupId);
                },
              ),
            ],
          ),
          GoRoute(
            path: 'settings',
            builder: (context, state) => const SettingsScreen(),
          ),
          GoRoute(
            path: 'nfc-tags',
            builder: (context, state) => const NfcTagsScreen(),
          ),
          GoRoute(
            path: 'catalog',
            builder: (context, state) => const BrowseCatalogScreen(),
            routes: [
              GoRoute(
                path: ':seriesId',
                builder: (context, state) {
                  final seriesId = state.pathParameters['seriesId']!;
                  return CatalogSeriesDetailScreen(seriesId: seriesId);
                },
              ),
            ],
          ),
        ],
      ),
    ],
  );
}

String? _globalRedirect(Ref ref, GoRouterState state) {
  final onboardingDone = ref.read(onboardingCompleteProvider);
  final isOnboarding = state.matchedLocation == AppRoutes.onboarding;

  // Redirect to onboarding if not completed
  if (!onboardingDone && !isOnboarding) {
    return AppRoutes.onboarding;
  }
  // Don't stay on onboarding if already completed
  if (onboardingDone && isOnboarding) {
    return AppRoutes.kidHome;
  }

  // Guard parent routes behind PIN
  final isParentRoute = state.matchedLocation.startsWith('/parent');
  if (isParentRoute) {
    final isAuthenticated = ref.read(parentAuthProvider);
    if (!isAuthenticated) {
      return AppRoutes.pinEntry;
    }
  }

  return null;
}

/// Bridges Riverpod state changes to GoRouter's [Listenable] refresh.
class _RouterRefreshNotifier extends ChangeNotifier {
  void notify() => notifyListeners();
}
