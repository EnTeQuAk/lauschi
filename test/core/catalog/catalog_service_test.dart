import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/catalog/catalog_service.dart';

void main() {
  late CatalogService catalog;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    catalog = await CatalogService.load();
  });

  group('CatalogService.load', () {
    test('loads at least 30 series', () {
      expect(catalog.seriesCount, greaterThanOrEqualTo(30));
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

    test('matches Biene Maja', () {
      final result = catalog.match('Biene Maja, Folge 5');
      expect(result, isNotNull);
      expect(result!.series.id, 'biene_maja');
      expect(result.episodeNumber, 5);
    });

    test('matches Hanni und Nanni', () {
      final result = catalog.match('Hanni und Nanni, Folge 12');
      expect(result, isNotNull);
      expect(result!.series.id, 'hanni_und_nanni');
    });

    test('matches Der kleine Drache Kokosnuss', () {
      final result = catalog.match('Der kleine Drache Kokosnuss, Folge 3');
      expect(result, isNotNull);
      expect(result!.series.id, 'kleiner_drache_kokosnuss');
      expect(result.episodeNumber, 3);
    });

    test('matches Fünf Freunde', () {
      final result = catalog.match('Fünf Freunde 50');
      expect(result, isNotNull);
      expect(result!.series.id, 'fuenf_freunde');
    });
  });
}
