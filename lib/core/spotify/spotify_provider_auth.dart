import 'package:lauschi/core/providers/provider_auth.dart';
import 'package:lauschi/core/providers/provider_type.dart';
import 'package:lauschi/core/spotify/spotify_session.dart';

/// Adapts [SpotifySession] to the [ProviderAuth] interface.
class SpotifyProviderAuth implements ProviderAuth {
  SpotifyProviderAuth(this._session);

  final SpotifySession _session;

  @override
  ProviderType get type => ProviderType.spotify;

  @override
  bool get requiresAuth => true;

  @override
  Future<void> authenticate() => _session.login();

  @override
  Future<void> logout() => _session.logout();
}
