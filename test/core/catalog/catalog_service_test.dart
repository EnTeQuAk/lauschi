import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/catalog/catalog_service.dart';

void main() {
  late CatalogService catalog;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    catalog = await CatalogService.load();
  });

  group('CatalogService.load', () {
    test('loads at least 10 series', () {
      expect(catalog.seriesCount, greaterThanOrEqualTo(10));
    });
  });

  group('CatalogService.match', () {
    test('matches Yakari by keyword', () {
      final result = catalog.match('Yakari, Folge 45 - Der böse Wolf');
      expect(result, isNotNull);
      expect(result!.series.id, 'yakari');
    });

    test('extracts episode number from Yakari title', () {
      final result = catalog.match('Yakari, Folge 45 - Der böse Wolf');
      expect(result!.episodeNumber, 45);
    });

    test('matches Bibi Blocksberg', () {
      final result = catalog.match('Bibi Blocksberg, Folge 1');
      expect(result, isNotNull);
      expect(result!.series.id, 'bibi_blocksberg');
    });

    test('matches Benjamin Blümchen case-insensitively', () {
      final result = catalog.match('benjamin blümchen - sonderedition');
      expect(result, isNotNull);
      expect(result!.series.id, 'benjamin_bluemchen');
    });

    test('matches TKKG with episode number', () {
      final result = catalog.match('TKKG 200');
      expect(result, isNotNull);
      expect(result!.series.id, 'tkkg');
      expect(result.episodeNumber, 200);
    });

    test('matches Die drei ???', () {
      final result = catalog.match('Die drei ??? 150');
      expect(result, isNotNull);
      expect(result!.series.id, 'die_drei_fragezeichen');
    });

    test('prefers Die drei ??? Kids over Die drei ??? (more specific)', () {
      // The "kids" keyword is longer so it should match first if present
      final result = catalog.match('Die drei ??? Kids, Folge 30');
      expect(result, isNotNull);
      expect(result!.series.id, 'die_drei_fragezeichen_kids');
    });

    test('returns null for unknown content', () {
      final result = catalog.match('Random Pop Album 2024');
      expect(result, isNull);
    });

    test('returns null for empty string', () {
      final result = catalog.match('');
      expect(result, isNull);
    });

    test('matches Pumuckl', () {
      final result = catalog.match('Pumuckl und das Geld');
      expect(result, isNotNull);
      expect(result!.series.id, 'pumuckl');
    });
  });
}
