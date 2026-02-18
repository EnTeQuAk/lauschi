// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'pin_service.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

String _$pinServiceHash() => r'bf1dd1c71fbdc18aea66afe776324414e3903658';

/// See also [pinService].
@ProviderFor(pinService)
final pinServiceProvider = Provider<PinService>.internal(
  pinService,
  name: r'pinServiceProvider',
  debugGetCreateSourceHash:
      const bool.fromEnvironment('dart.vm.product') ? null : _$pinServiceHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
typedef PinServiceRef = ProviderRef<PinService>;
String _$parentAuthHash() => r'ad5fd292e2130fa985f75135fb1ea917ac3979c5';

/// Whether the user is currently authenticated in parent mode.
/// Resets when the app is closed. Not persisted.
///
/// Copied from [ParentAuth].
@ProviderFor(ParentAuth)
final parentAuthProvider = NotifierProvider<ParentAuth, bool>.internal(
  ParentAuth.new,
  name: r'parentAuthProvider',
  debugGetCreateSourceHash:
      const bool.fromEnvironment('dart.vm.product') ? null : _$parentAuthHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

typedef _$ParentAuth = Notifier<bool>;
// ignore_for_file: type=lint
// ignore_for_file: subtype_of_sealed_class, invalid_use_of_internal_member, invalid_use_of_visible_for_testing_member, deprecated_member_use_from_same_package
