// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'card_repository.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

String _$cardRepositoryHash() => r'0bbdd4b042b9ce7facface0996256e765444ff0b';

/// See also [cardRepository].
@ProviderFor(cardRepository)
final cardRepositoryProvider = Provider<CardRepository>.internal(
  cardRepository,
  name: r'cardRepositoryProvider',
  debugGetCreateSourceHash:
      const bool.fromEnvironment('dart.vm.product')
          ? null
          : _$cardRepositoryHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
typedef CardRepositoryRef = ProviderRef<CardRepository>;
String _$allCardsHash() => r'38f2fe2a6e0e4781872b2811f16b2157237be797';

/// Stream of all cards, ordered by sortOrder.
///
/// Copied from [allCards].
@ProviderFor(allCards)
final allCardsProvider = AutoDisposeStreamProvider<List<Card>>.internal(
  allCards,
  name: r'allCardsProvider',
  debugGetCreateSourceHash:
      const bool.fromEnvironment('dart.vm.product') ? null : _$allCardsHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
typedef AllCardsRef = AutoDisposeStreamProviderRef<List<Card>>;
// ignore_for_file: type=lint
// ignore_for_file: subtype_of_sealed_class, invalid_use_of_internal_member, invalid_use_of_visible_for_testing_member, deprecated_member_use_from_same_package
