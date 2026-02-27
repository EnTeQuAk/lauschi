import 'package:lauschi/core/providers/provider_auth.dart';
import 'package:lauschi/core/providers/provider_type.dart';
import 'package:lauschi/core/spotify/spotify_auth_provider.dart';

/// Adapts SpotifyAuthNotifier to the ProviderAuth interface.
class SpotifyProviderAuth implements ProviderAuth {
  SpotifyProviderAuth(this._notifier);

  final SpotifyAuthNotifier _notifier;

  @override
  ProviderType get type => ProviderType.spotify;

  @override
  bool get requiresAuth => true;

  @override
  Future<void> authenticate() => _notifier.login();

  @override
  Future<void> logout() => _notifier.logout();
}
