// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'spotify_auth_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

String _$spotifyAuthHash() => r'6c55894a50fbc26d7c4b05a1f91437758cd90c72';

/// See also [spotifyAuth].
@ProviderFor(spotifyAuth)
final spotifyAuthProvider = Provider<SpotifyAuth>.internal(
  spotifyAuth,
  name: r'spotifyAuthProvider',
  debugGetCreateSourceHash:
      const bool.fromEnvironment('dart.vm.product') ? null : _$spotifyAuthHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
typedef SpotifyAuthRef = ProviderRef<SpotifyAuth>;
String _$spotifyAuthNotifierHash() =>
    r'c035d30b16320e891b8c984c468f039c1e49d574';

/// Manages Spotify authentication state.
///
/// On creation, attempts to load stored tokens. Exposes methods to
/// login, logout, and get a valid access token.
///
/// Copied from [SpotifyAuthNotifier].
@ProviderFor(SpotifyAuthNotifier)
final spotifyAuthNotifierProvider =
    NotifierProvider<SpotifyAuthNotifier, SpotifyAuthState>.internal(
      SpotifyAuthNotifier.new,
      name: r'spotifyAuthNotifierProvider',
      debugGetCreateSourceHash:
          const bool.fromEnvironment('dart.vm.product')
              ? null
              : _$spotifyAuthNotifierHash,
      dependencies: null,
      allTransitiveDependencies: null,
    );

typedef _$SpotifyAuthNotifier = Notifier<SpotifyAuthState>;
// ignore_for_file: type=lint
// ignore_for_file: subtype_of_sealed_class, invalid_use_of_internal_member, invalid_use_of_visible_for_testing_member, deprecated_member_use_from_same_package
