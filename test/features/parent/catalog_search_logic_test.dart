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

      // Context: the test title is only meaningful if the input
      // actually contains matches at indices 1+3 and nulls at 0+2.
      // Without these asserts, a broken `_match()` factory could
      // silently make the behavioral assertions below pass for the
      // wrong reason.
      expect(matches, hasLength(4), reason: 'setup: 4 albums');
      expect(matches[0], isNull, reason: 'setup: index 0 unmatched');
      expect(matches[1], isNotNull, reason: 'setup: index 1 matched (tkkg)');
      expect(matches[2], isNull, reason: 'setup: index 2 unmatched');
      expect(matches[3], isNotNull, reason: 'setup: index 3 matched (bibi)');

      final sorted = sortByCatalogMatch(matches, 4);

      // Context: sorted permutation preserves all input indices.
      expect(sorted, hasLength(4), reason: 'sort preserves element count');

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

      // Context: test name says "within matched group" — guarantee
      // every input slot is a match so there's nothing else to sort.
      expect(
        matches.every((m) => m != null),
        isTrue,
        reason: 'setup: all items are matches',
      );

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

      // Context: setup has 3 matches (tkkg/bibi/tkkg) and 1 null.
      // Two of the matches are tkkg (the hero), one is bibi (not a
      // hero). A broken `_match()` factory or accidental change to
      // the hero set would skip these checks without this guard.
      expect(matches, hasLength(4));
      expect(matches[0]?.series.id, 'tkkg');
      expect(matches[1], isNull);
      expect(matches[2]?.series.id, 'bibi');
      expect(matches[3]?.series.id, 'tkkg');
      expect(heroIds, {'tkkg'}, reason: 'only tkkg is a hero series');

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
