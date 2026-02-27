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
    this.enabled = true,
  });

  final ProviderType type;
  final ProviderAuth auth;
  final ProviderAuthState authState;

  /// Whether this provider is available in the current build.
  /// False for providers not yet implemented (Tidal).
  final bool enabled;

  /// Ready for use: enabled, and either no auth required or authenticated.
  bool get isAvailable =>
      enabled &&
      (authState == ProviderAuthState.authenticated || !auth.requiresAuth);
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
    ProviderInfo(
      type: ProviderType.appleMusic,
      auth: ArdAuth(), // placeholder, not wired
      authState: ProviderAuthState.unauthenticated,
      enabled: false,
    ),
    ProviderInfo(
      type: ProviderType.tidal,
      auth: ArdAuth(), // placeholder, not wired
      authState: ProviderAuthState.unauthenticated,
      enabled: false,
    ),
  ];
}

/// Convenience: providers that are enabled and authenticated.
@Riverpod(keepAlive: true)
List<ProviderInfo> availableProviders(Ref ref) {
  return ref.watch(providerRegistryProvider).where((p) => p.isAvailable).toList();
}
