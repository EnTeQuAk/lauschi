import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lauschi/features/cards/screens/kid_home_screen.dart';
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

  // Parent mode (PIN-gated)
  static const parentDashboard = '/parent';
  static const parentAddCard = '/parent/add-card';
  static const parentSettings = '/parent/settings';
  static const pinEntry = '/pin';
}

@Riverpod(keepAlive: true)
GoRouter appRouter(Ref ref) {
  return GoRouter(
    initialLocation: AppRoutes.kidHome,
    debugLogDiagnostics: true,
    redirect: _globalRedirect,
    routes: [
      GoRoute(
        path: AppRoutes.onboarding,
        builder: (context, state) => const _PlaceholderScreen(label: 'Onboarding'),
      ),
      GoRoute(
        path: AppRoutes.kidHome,
        builder: (context, state) => const KidHomeScreen(),
        routes: [
          GoRoute(
            path: 'player',
            builder: (context, state) => const PlayerScreen(),
          ),
        ],
      ),
      GoRoute(
        path: AppRoutes.pinEntry,
        builder: (context, state) => const _PlaceholderScreen(label: 'PIN Entry'),
      ),
      GoRoute(
        path: AppRoutes.parentDashboard,
        builder: (context, state) => const _PlaceholderScreen(label: 'Parent Dashboard'),
        routes: [
          GoRoute(
            path: 'add-card',
            builder: (context, state) => const _PlaceholderScreen(label: 'Add Card'),
          ),
          GoRoute(
            path: 'settings',
            builder: (context, state) => const _PlaceholderScreen(label: 'Settings'),
          ),
        ],
      ),
    ],
  );
}

String? _globalRedirect(BuildContext context, GoRouterState state) {
  // TODO(#10): redirect to /onboarding if first-run flag is set
  // TODO(#9): redirect /parent/* to /pin if not authenticated
  return null;
}

/// Placeholder while screens are being built feature-by-feature.
class _PlaceholderScreen extends StatelessWidget {
  const _PlaceholderScreen({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(label)),
      body: Center(
        child: Text(
          label,
          style: Theme.of(context).textTheme.headlineMedium,
        ),
      ),
    );
  }
}
