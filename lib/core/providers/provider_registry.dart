import 'package:lauschi/core/apple_music/apple_music_auth.dart';
import 'package:lauschi/core/apple_music/apple_music_session.dart';
import 'package:lauschi/core/ard/ard_auth.dart';
import 'package:lauschi/core/feature_flags.dart';
import 'package:lauschi/core/providers/provider_auth.dart';
import 'package:lauschi/core/providers/provider_type.dart';
import 'package:lauschi/core/spotify/spotify_provider_auth.dart';
import 'package:lauschi/core/spotify/spotify_session.dart';
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
  final providers = <ProviderInfo>[
    ProviderInfo(
      type: ProviderType.ardAudiothek,
      auth: ArdAuth(),
      authState: ProviderAuthState.authenticated,
    ),
  ];

  if (FeatureFlags.enableAppleMusic) {
    final amState = ref.watch(appleMusicSessionProvider);
    final amSession = ref.read(appleMusicSessionProvider.notifier);

    final amAuthState = switch (amState) {
      AppleMusicLoading() => ProviderAuthState.loading,
      AppleMusicAuthenticated() => ProviderAuthState.authenticated,
      AppleMusicUnauthenticated() => ProviderAuthState.unauthenticated,
      // For the registry's purposes, an errored session is the same
      // as unauthenticated: not usable, user must re-authenticate.
      // This mirrors how the Spotify case is handled below.
      AppleMusicError() => ProviderAuthState.unauthenticated,
    };

    providers.add(
      ProviderInfo(
        type: ProviderType.appleMusic,
        auth: AppleMusicProviderAuth(amSession),
        authState: amAuthState,
      ),
    );
  }

  if (FeatureFlags.enableSpotify) {
    final sessionState = ref.watch(spotifySessionProvider);
    final session = ref.read(spotifySessionProvider.notifier);

    final authState = switch (sessionState) {
      SpotifyLoading() => ProviderAuthState.loading,
      SpotifyAuthenticated() => ProviderAuthState.authenticated,
      SpotifyUnauthenticated() => ProviderAuthState.unauthenticated,
      SpotifyError() => ProviderAuthState.unauthenticated,
    };

    providers.add(
      ProviderInfo(
        type: ProviderType.spotify,
        auth: SpotifyProviderAuth(session),
        authState: authState,
      ),
    );
  }

  return providers;
}

/// Providers that are ready for use (authenticated or no-auth).
@Riverpod(keepAlive: true)
List<ProviderInfo> availableProviders(Ref ref) {
  return ref
      .watch(providerRegistryProvider)
      .where((p) => p.isAvailable)
      .toList();
}
