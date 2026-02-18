// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'player_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

String _$spotifyApiHash() => r'4284c81e71583130bd54b32f5fba3f01cbb0d83b';

/// See also [spotifyApi].
@ProviderFor(spotifyApi)
final spotifyApiProvider = Provider<SpotifyApi>.internal(
  spotifyApi,
  name: r'spotifyApiProvider',
  debugGetCreateSourceHash:
      const bool.fromEnvironment('dart.vm.product') ? null : _$spotifyApiHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
typedef SpotifyApiRef = ProviderRef<SpotifyApi>;
String _$spotifyPlayerBridgeHash() =>
    r'002c078b53f3b1219301629d8243620f1e4e09c0';

/// See also [spotifyPlayerBridge].
@ProviderFor(spotifyPlayerBridge)
final spotifyPlayerBridgeProvider = Provider<SpotifyPlayerBridge>.internal(
  spotifyPlayerBridge,
  name: r'spotifyPlayerBridgeProvider',
  debugGetCreateSourceHash:
      const bool.fromEnvironment('dart.vm.product')
          ? null
          : _$spotifyPlayerBridgeHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
typedef SpotifyPlayerBridgeRef = ProviderRef<SpotifyPlayerBridge>;
String _$playerNotifierHash() => r'89349ebdb2ee51f427b73cd7b0d62b56ca9f990b';

/// Manages playback state and coordinates bridge + API.
///
/// Copied from [PlayerNotifier].
@ProviderFor(PlayerNotifier)
final playerNotifierProvider =
    NotifierProvider<PlayerNotifier, PlaybackState>.internal(
      PlayerNotifier.new,
      name: r'playerNotifierProvider',
      debugGetCreateSourceHash:
          const bool.fromEnvironment('dart.vm.product')
              ? null
              : _$playerNotifierHash,
      dependencies: null,
      allTransitiveDependencies: null,
    );

typedef _$PlayerNotifier = Notifier<PlaybackState>;
// ignore_for_file: type=lint
// ignore_for_file: subtype_of_sealed_class, invalid_use_of_internal_member, invalid_use_of_visible_for_testing_member, deprecated_member_use_from_same_package
