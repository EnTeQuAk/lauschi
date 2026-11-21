import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lauschi/core/auth/pin_service.dart';
import 'package:lauschi/core/feature_flags.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/providers/provider_type.dart';
import 'package:lauschi/core/spotify/spotify_catalog_source.dart';
import 'package:lauschi/core/spotify/spotify_session.dart';
import 'package:lauschi/core/telemetry/telemetry.dart';
import 'package:lauschi/features/onboarding/screens/onboarding/screen.dart';
import 'package:lauschi/features/onboarding/screens/onboarding_provider.dart';
import 'package:lauschi/features/parent/screens/add_content_screen.dart';
import 'package:lauschi/features/parent/screens/ard_show_detail/screen.dart';
import 'package:lauschi/features/parent/screens/browse_catalog/screen.dart';
import 'package:lauschi/features/parent/screens/catalog_series_detail/screen.dart';
import 'package:lauschi/features/parent/screens/discover_screen.dart';
import 'package:lauschi/features/parent/screens/manage_tiles/screen.dart';
import 'package:lauschi/features/parent/screens/nfc_tags_screen.dart';
import 'package:lauschi/features/parent/screens/parent_dashboard_screen.dart';
import 'package:lauschi/features/parent/screens/pin_screen.dart';
import 'package:lauschi/features/parent/screens/settings/screen.dart';
import 'package:lauschi/features/parent/screens/tile_edit/screen.dart';
import 'package:lauschi/features/parent/screens/tile_item_edit/screen.dart';
import 'package:lauschi/features/player/screens/player/screen.dart';
import 'package:lauschi/features/tiles/screens/kid_home_screen.dart';
import 'package:lauschi/features/tiles/screens/tile_detail/screen.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'app_router.g.dart';

const _tag = 'AppRouter';

// Route paths: single source of truth
/// Root navigator key, shared between the router and overlays that need
/// a navigator context from outside the widget tree (PlayerErrorHost).
final rootNavigatorKeyProvider = Provider<GlobalKey<NavigatorState>>(
  (ref) => GlobalKey<NavigatorState>(debugLabel: 'rootNavigator'),
);

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
  static const parentManageTiles = '/parent/tiles';
  static String parentTileEdit(String tileId) => '/parent/tiles/$tileId';
  static String parentTileChildren(String tileId) =>
      '/parent/tiles/$tileId/children';
  static String parentTileItemEdit(String itemId) => '/parent/items/$itemId';
  static const parentSettings = '/parent/settings';
  static const parentNfcTags = '/parent/nfc-tags';
  static const parentAddContent = '/parent/add';
  static String parentAddToTile(String tileId) => '/parent/add?tileId=$tileId';
  static const parentCatalog = '/parent/catalog';
  // The tile a screen fills goes in the URL, not in go_router's extra, so
  // it survives the PIN screen sending the parent back to the location.
  static String parentCatalogSeries(
    String seriesId, {
    required ProviderType provider,
    String? tileId,
  }) =>
      Uri(
        path: '/parent/catalog/$seriesId',
        queryParameters: {
          'provider': provider.value,
          if (tileId != null) 'tileId': tileId,
        },
      ).toString();
  static const parentDiscover = '/parent/discover';
  static String parentDiscoverShow(String showId, {String? tileId}) =>
      Uri(
        path: '/parent/discover/$showId',
        queryParameters: {if (tileId != null) 'tileId': tileId},
      ).toString();
  static const pinEntry = '/pin';
  static const pinChange = '/pin/change';
}

/// Tells screens when a route above them is pushed or popped, e.g. the
/// episode grid scrolling to the Weiter card when the kid comes back from
/// the player.
final routeObserver = RouteObserver<ModalRoute<void>>();

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
    ref.listen(spotifySessionProvider, (_, _) => refreshNotifier.notify());
  }
  ref.onDispose(refreshNotifier.dispose);

  final rootNavigatorKey = ref.watch(rootNavigatorKeyProvider);

  late final GoRouter router;
  return router = GoRouter(
    navigatorKey: rootNavigatorKey,
    initialLocation: initialLocation,
    debugLogDiagnostics: true,
    refreshListenable: refreshNotifier,
    observers: [
      ...telemetry.navigatorObservers,
      SnackBarClearObserver(rootNavigatorKey),
      routeObserver,
    ],
    redirect:
        (context, state) => _globalRedirect(
          ref,
          state,
          shown: router.routerDelegate.currentConfiguration,
        ),
    // A stale deep link or NFC tag can carry a path no route matches.
    // go_router shows its own English error page for that, so this sends
    // you to the kid home instead. The guard stops a loop if the home
    // itself fails.
    onException: (context, state, router) {
      Log.warn(_tag, 'No route for location', data: {'uri': state.uri});
      if (state.uri.path != AppRoutes.kidHome) router.go(AppRoutes.kidHome);
    },
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
        builder:
            (context, state) =>
                PinScreen(returnTo: state.uri.queryParameters['from']),
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
                routes: [
                  GoRoute(
                    name: 'parent-tile-children',
                    path: 'children',
                    builder: (context, state) {
                      final tileId = state.pathParameters['id']!;
                      return ManageTilesScreen(parentTileId: tileId);
                    },
                  ),
                ],
              ),
            ],
          ),
          GoRoute(
            name: 'parent-tile-item-edit',
            path: 'items/:id',
            builder: (context, state) {
              final itemId = state.pathParameters['id']!;
              return TileItemEditScreen(itemId: itemId);
            },
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
            builder: (context, state) {
              // Standalone catalog route: always Spotify.
              final session = ref.read(spotifySessionProvider);
              if (session is! SpotifyAuthenticated) {
                return const Scaffold(
                  body: Center(child: Text('Spotify nicht verbunden')),
                );
              }
              return BrowseCatalogScreen(
                catalogSource: SpotifyCatalogSource(
                  ref.read(spotifySessionProvider.notifier).api,
                ),
              );
            },
            routes: [
              GoRoute(
                name: 'parent-catalog-series',
                path: ':seriesId',
                builder: (context, state) {
                  final seriesId = state.pathParameters['seriesId']!;
                  final providerStr =
                      state.uri.queryParameters['provider'] ?? 'spotify';
                  return CatalogSeriesDetailScreen(
                    seriesId: seriesId,
                    provider: ProviderType.fromString(providerStr),
                    autoAssignTileId: state.uri.queryParameters['tileId'],
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
                  final extra = state.extra as ShowDetailExtra?;
                  return ArdShowDetailScreen(
                    showId: showId,
                    autoAssignTileId: state.uri.queryParameters['tileId'],
                    highlightEpisodeUris: extra?.highlightEpisodeUris,
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

/// The location the parent sees when [state] re-checks the [shown] one.
/// The redirect then runs for the location below the screens opened with
/// push, so this is the top one of those.
Uri _shownLocation(GoRouterState state, RouteMatchList shown) {
  if (shown.isEmpty || state.uri != shown.uri) return state.uri;
  return switch (shown.matches.last) {
    ImperativeRouteMatch(:final matches) => matches.uri,
    _ => state.uri,
  };
}

String? _globalRedirect(
  Ref ref,
  GoRouterState state, {
  required RouteMatchList shown,
}) {
  final onboardingDone = ref.read(onboardingCompleteProvider);
  final isOnboarding = state.matchedLocation == AppRoutes.onboarding;

  Log.debug(
    _tag,
    'Redirect check',
    data: {'path': state.matchedLocation, 'onboardingDone': '$onboardingDone'},
  );

  // Redirect to onboarding if not completed
  if (!onboardingDone && !isOnboarding) {
    Log.info(
      _tag,
      'Redirecting to onboarding',
      data: {'from': state.matchedLocation},
    );
    return AppRoutes.onboarding;
  }
  // Don't stay on onboarding if already completed
  if (onboardingDone && isOnboarding) {
    Log.info(_tag, 'Onboarding done, redirecting to home');
    return AppRoutes.kidHome;
  }

  // Guard parent routes behind PIN
  if (isParentLocation(state.matchedLocation)) {
    final isAuthenticated = ref.read(parentAuthProvider);
    if (!isAuthenticated) {
      Log.info(
        _tag,
        'Parent route not authenticated, redirecting to PIN',
        data: {'from': state.matchedLocation},
      );
      // Like a login's ?next=, so the PIN screen can continue to where
      // the parent was going, or was when the session ended, instead of
      // the dashboard.
      return Uri(
        path: AppRoutes.pinEntry,
        queryParameters: {'from': '${_shownLocation(state, shown)}'},
      ).toString();
    }
    // Extend the session on genuine navigation so active parents aren't
    // logged out. touch() ignores repeats for the same location, so a
    // refresh-triggered re-eval (e.g. a Spotify token refresh) can't keep
    // resetting the inactivity timer while the parent sits idle.
    ref.read(parentAuthProvider.notifier).touch(state.matchedLocation);
  }

  return null;
}

/// Where the PIN screen sends the parent after unlocking: the parent
/// location the PIN gate interrupted, or the dashboard. Only a path inside
/// the parent area counts, so whatever ends up in `from` can't send the
/// unlocked session anywhere else.
String parentReturnLocation(String? from) {
  final uri = from == null ? null : Uri.tryParse(from);
  if (uri == null || uri.hasScheme || uri.hasAuthority) {
    return AppRoutes.parentDashboard;
  }
  return isParentLocation(uri.path) ? from! : AppRoutes.parentDashboard;
}

/// Whether [path] is in the parent area, the part behind the PIN.
bool isParentLocation(String path) =>
    path == AppRoutes.parentDashboard ||
    path.startsWith('${AppRoutes.parentDashboard}/');

/// Bridges Riverpod state changes to GoRouter's [Listenable] refresh.
class _RouterRefreshNotifier extends ChangeNotifier {
  void notify() => notifyListeners();
}

/// Clears stale snackbars when navigating *forward* into a new screen, so a
/// leftover "hinzugefügt" message doesn't linger across routes.
///
/// Deliberately does not clear on `didPop`: the delete-then-pop flows (tile
/// and item delete) show their "Rückgängig" undo snackbar for the screen
/// they pop back to, and a pop-triggered clear would wipe it before the
/// parent could tap it.
@visibleForTesting
class SnackBarClearObserver extends NavigatorObserver {
  SnackBarClearObserver(this._navigatorKey);

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
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      _clearSnackBars();
}
