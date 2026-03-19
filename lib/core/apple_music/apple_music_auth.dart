import 'package:lauschi/core/apple_music/apple_music_session.dart';
import 'package:lauschi/core/providers/provider_auth.dart';
import 'package:lauschi/core/providers/provider_type.dart';

/// Adapts AppleMusicSession to the ProviderAuth interface.
///
/// Same pattern as SpotifyProviderAuth: thin adapter, no state of its own.
class AppleMusicProviderAuth implements ProviderAuth {
  AppleMusicProviderAuth(this._session);

  final AppleMusicSession _session;

  @override
  ProviderType get type => ProviderType.appleMusic;

  @override
  bool get requiresAuth => true;

  @override
  Future<void> authenticate() => _session.connect();

  @override
  Future<void> logout() => _session.disconnect();
}
