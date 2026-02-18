// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'onboarding_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

String _$onboardingCompleteHash() =>
    r'49a0e209ef550f21cdf4e32ec919e7cdadf6b0d0';

/// Tracks whether onboarding has been completed.
///
/// Reads from SharedPreferences on first access. The router
/// redirects to /onboarding if this is false.
///
/// Copied from [OnboardingComplete].
@ProviderFor(OnboardingComplete)
final onboardingCompleteProvider =
    NotifierProvider<OnboardingComplete, bool>.internal(
      OnboardingComplete.new,
      name: r'onboardingCompleteProvider',
      debugGetCreateSourceHash:
          const bool.fromEnvironment('dart.vm.product')
              ? null
              : _$onboardingCompleteHash,
      dependencies: null,
      allTransitiveDependencies: null,
    );

typedef _$OnboardingComplete = Notifier<bool>;
// ignore_for_file: type=lint
// ignore_for_file: subtype_of_sealed_class, invalid_use_of_internal_member, invalid_use_of_visible_for_testing_member, deprecated_member_use_from_same_package
