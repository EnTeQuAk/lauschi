import 'package:lauschi/core/providers/provider_type.dart';

/// Authentication state for a content provider.
///
/// Providers that require no auth (ARD) are always [authenticated].
/// SDK providers (Spotify, Apple Music) go through OAuth flows.
enum ProviderAuthState {
  /// Initial state, checking for stored credentials.
  loading,

  /// No valid credentials. Provider cannot be used.
  unauthenticated,

  /// Credentials valid. Provider is usable.
  authenticated,
}

/// Auth contract for a content provider.
///
/// Implementations are thin adapters over provider-specific auth.
/// The registry uses Riverpod to watch state changes reactively,
/// so this interface is deliberately simple (no streams).
abstract class ProviderAuth {
  ProviderType get type;

  /// Whether this provider requires user authentication.
  /// False for free providers like ARD Audiothek.
  bool get requiresAuth;

  /// Start the authentication flow (OAuth, MusicKit, etc.).
  /// No-op for providers that don't require auth.
  Future<void> authenticate();

  /// Clear credentials and return to unauthenticated.
  Future<void> logout();
}
