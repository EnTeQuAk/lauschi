import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/ard/ard_helpers.dart';
import 'package:lauschi/core/ard/ard_models.dart';

void main() {
  group('parseHexColor', () {
    test('parses valid hex color', () {
      expect(parseHexColor('#FF6B00'), const Color(0xFFFF6B00));
      expect(parseHexColor('#003480'), const Color(0xFF003480));
    });

    test('returns null for invalid input', () {
      expect(parseHexColor(null), isNull);
      expect(parseHexColor(''), isNull);
      expect(parseHexColor('#ZZZ'), isNull);
    });
  });

  group('ArdGroup', () {
    test('parses from JSON', () {
      final json = <String, dynamic>{
        'title': 'Superhelden :',
        'type': 'MULTIPART',
        'count': 5,
      };
      final group = ArdGroup.fromJson(json);
      expect(group.title, 'Superhelden :');
      expect(group.type, 'MULTIPART');
      expect(group.count, 5);
    });

    test('displayTitle strips trailing colon', () {
      final group = ArdGroup.fromJson(<String, dynamic>{
        'title': 'Superhelden :',
        'type': 'MULTIPART',
        'count': 5,
      });
      expect(group.displayTitle, 'Superhelden');
    });

    test('displayTitle preserves clean titles', () {
      final group = ArdGroup.fromJson(<String, dynamic>{
        'title': 'Die große Reise',
      });
      expect(group.displayTitle, 'Die große Reise');
    });
  });

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

    test('parses groupId and group from JSON', () {
      final json = <String, dynamic>{
        'id': 10458067,
        'title': 'Superhelden (1/5): Turnverein',
        'titleClean': 'Superhelden: Turnverein',
        'publishDate': '2025-02-25T00:00:00Z',
        'episodeNumber': 1,
        'groupId': '10458067',
        'group': {
          'title': 'Superhelden :',
          'type': 'MULTIPART',
          'count': 5,
        },
        'audios': <dynamic>[],
      };

      final item = ArdItem.fromJson(json);

      expect(item.groupId, '10458067');
      expect(item.group, isNotNull);
      expect(item.group!.displayTitle, 'Superhelden');
      expect(item.group!.count, 5);
      expect(item.group!.type, 'MULTIPART');
    });

    test('handles missing group fields', () {
      final json = <String, dynamic>{
        'id': 123,
        'title': 'Standalone episode',
        'publishDate': '2025-02-25T00:00:00Z',
        'audios': <dynamic>[],
      };

      final item = ArdItem.fromJson(json);

      expect(item.groupId, isNull);
      expect(item.group, isNull);
    });
  });
}
