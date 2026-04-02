import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/catalog/catalog_service.dart';
import 'package:lauschi/features/parent/screens/browse_catalog/widgets/catalog_helpers.dart';

CatalogMatch _match(String seriesId) => CatalogMatch(
  series: CatalogSeries(
    id: seriesId,
    title: seriesId,
    aliases: const [],
    keywords: const [],
    spotifyArtistIds: const [],
  ),
  source: CatalogMatchSource.keyword,
);

void main() {
  group('sortByCatalogMatch', () {
    test('matched albums come before unmatched', () {
      final matches = <CatalogMatch?>[
        null,
        _match('tkkg'),
        null,
        _match('bibi'),
      ];
      final sorted = sortByCatalogMatch(matches, 4);
      // Indices 1 and 3 have matches, should come first.
      expect(sorted[0], 1);
      expect(sorted[1], 3);
      // Indices 0 and 2 are unmatched.
      expect(sorted[2], 0);
      expect(sorted[3], 2);
    });

    test('preserves order within matched group', () {
      final matches = <CatalogMatch?>[
        _match('a'),
        _match('b'),
        _match('c'),
      ];
      final sorted = sortByCatalogMatch(matches, 3);
      expect(sorted, [0, 1, 2]);
    });

    test('handles empty list', () {
      expect(sortByCatalogMatch([], 0), isEmpty);
    });
  });

  group('partitionByHeroSeries', () {
    test('splits into matching and non-matching', () {
      final matches = <CatalogMatch?>[
        _match('tkkg'),
        null,
        _match('bibi'),
        _match('tkkg'),
      ];
      final heroIds = {'tkkg'};

      final result = partitionByHeroSeries(matches, heroIds, 4);
      expect(result.matching, [0, 3]); // tkkg matches
      expect(result.nonMatching, [1, 2]); // null and bibi (not a hero)
    });

    test('all non-matching when no heroes', () {
      final matches = <CatalogMatch?>[_match('a'), _match('b')];
      final result = partitionByHeroSeries(matches, <String>{}, 2);
      expect(result.matching, isEmpty);
      expect(result.nonMatching, [0, 1]);
    });

    test('handles count larger than matches list', () {
      final matches = <CatalogMatch?>[_match('a')];
      final result = partitionByHeroSeries(matches, {'a'}, 3);
      expect(result.matching, [0]);
      expect(result.nonMatching, [1, 2]);
    });
  });
}
