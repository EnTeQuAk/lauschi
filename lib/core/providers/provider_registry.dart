import 'package:lauschi/core/ard/ard_auth.dart';
import 'package:lauschi/core/providers/provider_auth.dart';
import 'package:lauschi/core/providers/provider_type.dart';
import 'package:lauschi/core/spotify/spotify_auth_provider.dart';
import 'package:lauschi/core/spotify/spotify_provider_auth.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'provider_registry.g.dart';

/// Info about a registered content provider.
class ProviderInfo {
  const ProviderInfo({
    required this.type,
    required this.auth,
    required this.authState,
  });

  final ProviderType type;
  final ProviderAuth auth;
  final ProviderAuthState authState;

  /// Ready for use: no auth required or authenticated.
  bool get isAvailable =>
      authState == ProviderAuthState.authenticated || !auth.requiresAuth;

  /// Whether the parent can disconnect this provider.
  bool get canDisconnect =>
      auth.requiresAuth && authState == ProviderAuthState.authenticated;
}

/// Central registry of all content providers.
///
/// Watches auth state for each provider reactively. UI reads this
/// to decide which provider tabs to show, which settings to render,
/// and which providers can play content.
@Riverpod(keepAlive: true)
List<ProviderInfo> providerRegistry(Ref ref) {
  // Spotify auth state (reactive via Riverpod watch).
  final spotifyState = ref.watch(spotifyAuthProvider);
  final spotifyAuthState = switch (spotifyState) {
    AuthLoading() => ProviderAuthState.loading,
    AuthAuthenticated() => ProviderAuthState.authenticated,
    AuthUnauthenticated() => ProviderAuthState.unauthenticated,
    AuthError() => ProviderAuthState.unauthenticated,
  };

  final spotifyNotifier = ref.read(spotifyAuthProvider.notifier);

  // Only include providers that are implemented.
  // Apple Music and Tidal will be added here when their auth is wired.
  return [
    ProviderInfo(
      type: ProviderType.ardAudiothek,
      auth: ArdAuth(),
      authState: ProviderAuthState.authenticated,
    ),
    ProviderInfo(
      type: ProviderType.spotify,
      auth: SpotifyProviderAuth(spotifyNotifier),
      authState: spotifyAuthState,
    ),
  ];
}

/// Providers that are ready for use (authenticated or no-auth).
@Riverpod(keepAlive: true)
List<ProviderInfo> availableProviders(Ref ref) {
  return ref
      .watch(providerRegistryProvider)
      .where((p) => p.isAvailable)
      .toList();
}
