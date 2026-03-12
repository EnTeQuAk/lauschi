import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lauschi/core/auth/pin_service.dart';
import 'package:lauschi/core/feature_flags.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/providers/provider_type.dart';
import 'package:lauschi/core/spotify/spotify_auth_provider.dart';
import 'package:lauschi/features/onboarding/screens/onboarding_provider.dart';
import 'package:lauschi/features/onboarding/screens/onboarding_screen.dart';
import 'package:lauschi/features/parent/screens/add_content_screen.dart';
import 'package:lauschi/features/parent/screens/ard_show_detail_screen.dart';
import 'package:lauschi/features/parent/screens/browse_catalog_screen.dart';
import 'package:lauschi/features/parent/screens/discover_screen.dart';
import 'package:lauschi/features/parent/screens/manage_cards_screen.dart';
import 'package:lauschi/features/parent/screens/manage_tiles_screen.dart';
import 'package:lauschi/features/parent/screens/nfc_tags_screen.dart';
import 'package:lauschi/features/parent/screens/parent_dashboard_screen.dart';
import 'package:lauschi/features/parent/screens/pin_screen.dart';
import 'package:lauschi/features/parent/screens/settings_screen.dart';
import 'package:lauschi/features/parent/screens/tile_edit_screen.dart';
import 'package:lauschi/features/player/screens/player_screen.dart';
import 'package:lauschi/features/tiles/screens/kid_home_screen.dart';
import 'package:lauschi/features/tiles/screens/tile_detail_screen.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

part 'app_router.g.dart';

const _tag = 'AppRouter';

// Route paths — single source of truth
abstract final class AppRoutes {
  // Onboarding
  static const onboarding = '/onboarding';

  // Kid mode (root)
  static const kidHome = '/';
  static const player = '/player';

  // Tile drill-down (kid taps a tile on home screen)
  static String tileDetail(String tileId) => '/tile/$tileId';

  // Parent mode (PIN-gated)
  static const parentDashboard = '/parent';
  static const parentManageCards = '/parent/cards';

  static const parentManageTiles = '/parent/tiles';
  static String parentTileEdit(String tileId) => '/parent/tiles/$tileId';
  static const parentSettings = '/parent/settings';
  static const parentNfcTags = '/parent/nfc-tags';
  static const parentAddContent = '/parent/add';
  static String parentAddToTile(String tileId) => '/parent/add?tileId=$tileId';
  static const parentCatalog = '/parent/catalog';
  static String parentCatalogSeries(String seriesId) =>
      '/parent/catalog/$seriesId';
  static const parentDiscover = '/parent/discover';
  static String parentDiscoverShow(String showId) => '/parent/discover/$showId';
  static const pinEntry = '/pin';
  static const pinChange = '/pin/change';
}

@Riverpod(keepAlive: true)
GoRouter appRouter(Ref ref) => createRouter(ref);

/// Creates the app router. Extracted so tests can override
/// [initialLocation] without duplicating route definitions.
GoRouter createRouter(Ref ref, {String initialLocation = AppRoutes.kidHome}) {
  // Re-evaluate redirects when auth or onboarding state changes.
  final refreshNotifier = _RouterRefreshNotifier();
  ref
    ..listen(onboardingCompleteProvider, (_, _) => refreshNotifier.notify())
    ..listen(parentAuthProvider, (_, _) => refreshNotifier.notify());
  if (FeatureFlags.enableSpotify) {
    ref.listen(spotifyAuthProvider, (_, _) => refreshNotifier.notify());
  }
  ref.onDispose(refreshNotifier.dispose);

  final rootNavigatorKey = GlobalKey<NavigatorState>();

  return GoRouter(
    navigatorKey: rootNavigatorKey,
    initialLocation: initialLocation,
    debugLogDiagnostics: true,
    refreshListenable: refreshNotifier,
    observers: [
      SentryNavigatorObserver(),
      _SnackBarClearObserver(rootNavigatorKey),
    ],
    redirect: (context, state) => _globalRedirect(ref, state),
    routes: [
      GoRoute(
        name: 'onboarding',
        path: AppRoutes.onboarding,
        builder: (context, state) => const OnboardingScreen(),
      ),
      GoRoute(
        name: 'kid-home',
        path: AppRoutes.kidHome,
        builder: (context, state) => const KidHomeScreen(),
        routes: [
          GoRoute(
            name: 'player',
            path: 'player',
            builder: (context, state) => const PlayerScreen(),
          ),
          GoRoute(
            name: 'tile-detail',
            path: 'tile/:id',
            builder: (context, state) {
              final tileId = state.pathParameters['id']!;
              return TileDetailScreen(tileId: tileId);
            },
          ),
        ],
      ),
      GoRoute(
        name: 'pin-entry',
        path: AppRoutes.pinEntry,
        builder: (context, state) => const PinScreen(),
      ),
      GoRoute(
        name: 'pin-change',
        path: AppRoutes.pinChange,
        builder: (context, state) => const PinScreen(isChange: true),
      ),
      GoRoute(
        name: 'parent-dashboard',
        path: AppRoutes.parentDashboard,
        builder: (context, state) => const ParentDashboardScreen(),
        routes: [
          GoRoute(
            name: 'parent-cards',
            path: 'cards',
            builder: (context, state) => const ManageCardsScreen(),
          ),

          GoRoute(
            name: 'parent-tiles',
            path: 'tiles',
            builder: (context, state) => const ManageTilesScreen(),
            routes: [
              GoRoute(
                name: 'parent-tile-edit',
                path: ':id',
                builder: (context, state) {
                  final tileId = state.pathParameters['id']!;
                  return TileEditScreen(tileId: tileId);
                },
              ),
            ],
          ),
          GoRoute(
            name: 'parent-settings',
            path: 'settings',
            builder: (context, state) => const SettingsScreen(),
          ),
          GoRoute(
            name: 'parent-nfc-tags',
            path: 'nfc-tags',
            builder: (context, state) => const NfcTagsScreen(),
          ),
          GoRoute(
            name: 'parent-add-content',
            path: 'add',
            builder: (context, state) {
              final tileId = state.uri.queryParameters['tileId'];
              final initialTab = state.extra as ProviderType?;
              return AddContentScreen(
                initialTab: initialTab,
                autoAssignTileId: tileId,
              );
            },
          ),
          GoRoute(
            name: 'parent-catalog',
            path: 'catalog',
            builder: (context, state) => const BrowseCatalogScreen(),
            routes: [
              GoRoute(
                name: 'parent-catalog-series',
                path: ':seriesId',
                builder: (context, state) {
                  final seriesId = state.pathParameters['seriesId']!;
                  final autoAssignTileId = state.extra as String?;
                  return CatalogSeriesDetailScreen(
                    seriesId: seriesId,
                    autoAssignTileId: autoAssignTileId,
                  );
                },
              ),
            ],
          ),
          GoRoute(
            name: 'parent-discover',
            path: 'discover',
            builder: (context, state) => const DiscoverScreen(),
            routes: [
              GoRoute(
                name: 'parent-discover-show',
                path: ':showId',
                builder: (context, state) {
                  final showId = state.pathParameters['showId']!;
                  final autoAssignTileId = state.extra as String?;
                  return ArdShowDetailScreen(
                    showId: showId,
                    autoAssignTileId: autoAssignTileId,
                  );
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

  Log.debug(
    _tag,
    'Redirect check',
    data: {
      'path': state.matchedLocation,
      'onboardingDone': '$onboardingDone',
    },
  );

  // Redirect to onboarding if not completed
  if (!onboardingDone && !isOnboarding) {
    Log.info(
      _tag,
      'Redirecting to onboarding',
      data: {
        'from': state.matchedLocation,
      },
    );
    return AppRoutes.onboarding;
  }
  // Don't stay on onboarding if already completed
  if (onboardingDone && isOnboarding) {
    Log.info(_tag, 'Onboarding done, redirecting to home');
    return AppRoutes.kidHome;
  }

  // Guard parent routes behind PIN
  final isParentRoute = state.matchedLocation.startsWith('/parent');
  if (isParentRoute) {
    final isAuthenticated = ref.read(parentAuthProvider);
    if (!isAuthenticated) {
      Log.info(
        _tag,
        'Parent route not authenticated, redirecting to PIN',
        data: {
          'from': state.matchedLocation,
        },
      );
      return AppRoutes.pinEntry;
    }
  }

  return null;
}

/// Bridges Riverpod state changes to GoRouter's [Listenable] refresh.
class _RouterRefreshNotifier extends ChangeNotifier {
  void notify() => notifyListeners();
}

/// Clears any visible snackbars when navigating between screens.
/// Prevents stale "hinzugefügt" messages from lingering across routes.
class _SnackBarClearObserver extends NavigatorObserver {
  _SnackBarClearObserver(this._navigatorKey);

  final GlobalKey<NavigatorState> _navigatorKey;

  void _clearSnackBars() {
    final context = _navigatorKey.currentContext;
    if (context != null) {
      ScaffoldMessenger.maybeOf(context)?.clearSnackBars();
    }
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _clearSnackBars();

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _clearSnackBars();

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      _clearSnackBars();
}
