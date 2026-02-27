import 'package:lauschi/core/providers/provider_auth.dart';
import 'package:lauschi/core/providers/provider_type.dart';

/// Auth for ARD Audiothek. Always authenticated (no auth required).
class ArdAuth implements ProviderAuth {
  @override
  ProviderType get type => ProviderType.ardAudiothek;

  @override
  bool get requiresAuth => false;

  @override
  Future<void> authenticate() async {}

  @override
  Future<void> logout() async {}
}
