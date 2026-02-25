import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/ard/ard_models.dart';

void main() {
  group('ArdProgramSet.fromJson', () {
    test('parses new fields from JSON', () {
      final json = <String, dynamic>{
        'id': 7244594,
        'title': 'Betthupferl',
        'synopsis': 'Gute-Nacht-Geschichten',
        'description': '<p>Geschichten ab 4 Jahren</p>',
        'showType': 'INFINITE_SERIES',
        'numberOfElements': 800,
        'lastItemAdded': '2025-02-25T00:00:00Z',
        'feedUrl': 'https://example.com/feed.xml',
        'image': {'url1X1': 'https://img.test/{width}'},
        'publicationService': {
          'title': 'Bayern 2',
          'brandingColor': '#FF6B00',
          'organization': {'name': 'BR'},
        },
      };

      final show = ArdProgramSet.fromJson(json);

      expect(show.id, '7244594');
      expect(show.title, 'Betthupferl');
      expect(show.showType, 'INFINITE_SERIES');
      expect(show.description, '<p>Geschichten ab 4 Jahren</p>');
      expect(show.organizationName, 'BR');
      expect(show.brandingColor, '#FF6B00');
      expect(show.publisher, 'Bayern 2');
    });

    test('handles missing new fields gracefully', () {
      final json = <String, dynamic>{
        'id': 123,
        'title': 'Minimal Show',
      };

      final show = ArdProgramSet.fromJson(json);

      expect(show.showType, isNull);
      expect(show.description, isNull);
      expect(show.organizationName, isNull);
      expect(show.brandingColor, isNull);
    });

    test('handles publicationService without organization', () {
      final json = <String, dynamic>{
        'id': 456,
        'title': 'Test',
        'publicationService': {
          'title': 'SWR Kultur',
          'brandingColor': '#003480',
        },
      };

      final show = ArdProgramSet.fromJson(json);

      expect(show.publisher, 'SWR Kultur');
      expect(show.brandingColor, '#003480');
      expect(show.organizationName, isNull);
    });
  });

  group('ArdItem.fromJson', () {
    test('parses titleClean', () {
      final json = <String, dynamic>{
        'id': 15956139,
        'title':
            'Superhelden: Turnverein | Gute-Nacht-Geschichte ab 5 Jahren',
        'titleClean': 'Superhelden: Turnverein',
        'publishDate': '2025-02-25T00:00:00Z',
        'duration': 240,
        'audios': <dynamic>[],
      };

      final item = ArdItem.fromJson(json);

      expect(item.title, contains('Gute-Nacht-Geschichte'));
      expect(item.titleClean, 'Superhelden: Turnverein');
      expect(item.displayTitle, 'Superhelden: Turnverein');
    });

    test('displayTitle falls back to title when titleClean is null', () {
      final json = <String, dynamic>{
        'id': 123,
        'title': 'Pumuckl und der verstauchte Daumen',
        'publishDate': '2025-02-25T00:00:00Z',
        'audios': <dynamic>[],
      };

      final item = ArdItem.fromJson(json);

      expect(item.titleClean, isNull);
      expect(item.displayTitle, 'Pumuckl und der verstauchte Daumen');
    });
  });
}
