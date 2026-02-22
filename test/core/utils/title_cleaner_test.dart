import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/utils/title_cleaner.dart';

void main() {
  group('parseEpisodeNumber', () {
    group('extracts from Folge prefix', () {
      final cases = <(String, int)>[
        ('Folge 1: Hexen gibt es doch', 1),
        ('Folge 38: Eile mit Weile (Das Original-Hörspiel zur TV-Serie)', 38),
        ('Folge 100: 100 Stunden', 100),
        (
          'Folge 396: Das Eisbärenjunge (Das Original-Hörspiel zur TV-Serie)',
          396,
        ),
        ('Folge 15', 15),
        (
          'Folge 3 - Die Zauberlimonade (Das Original-Hörspiel zur TV-Serie)',
          3,
        ),
      ];

      for (final (input, expected) in cases) {
        test('"$input" → $expected', () {
          expect(parseEpisodeNumber(input), expected);
        });
      }
    });

    group('extracts from Episode prefix', () {
      test('Episode 12: The Great Storm → 12', () {
        expect(parseEpisodeNumber('Episode 12: The Great Storm'), 12);
      });
    });

    group('extracts from NNN/ format', () {
      final cases = <(String, int)>[
        ('031/Rückkehr der Saurier', 31),
        ('040/Brennendes Eis', 40),
        ('04/und die Einsiedlerkrebse', 4),
        ('001/Bob der Küchenmeister', 1),
        ('140/Draculas Erben', 140),
      ];

      for (final (input, expected) in cases) {
        test('"$input" → $expected', () {
          expect(parseEpisodeNumber(input), expected);
        });
      }
    });

    group('returns null when no pattern matches', () {
      final noMatch = [
        'Der Anfang der Schlangen',
        'Momo',
        'heilt den Bürgermeister',
        'Oh, wie schön ist Panama',
        'Conni auf dem Bauernhof / Conni und das neue Baby',
        'Die Olchis und der Geist der blauen Berge',
        '1: Der Räuber Hotzenplotz',
        'Golden Heart',
        'Bobo Siebenschläfer. Großer Sommerspaß.',
      ];

      for (final title in noMatch) {
        test('"$title" → null', () {
          expect(parseEpisodeNumber(title), isNull);
        });
      }
    });

    test('does not match single digit without slash', () {
      // "1: Der Räuber Hotzenplotz" — single digit + colon is not NNN/ format.
      expect(parseEpisodeNumber('1: Der Räuber Hotzenplotz'), isNull);
    });
  });

  group('cleanEpisodeTitle', () {
    group('strips Hörspiel parenthetical suffixes', () {
      final cases = <(String, String)>[
        (
          'Folge 38: Eile mit Weile (Das Original-Hörspiel zur TV-Serie)',
          'Eile mit Weile',
        ),
        (
          'Folge 11: Die Suche nach Kleiner Donner (Das Original-Hörspiel zur TV-Serie)',
          'Die Suche nach Kleiner Donner',
        ),
        (
          'Folge 3 - Die Zauberlimonade (Das Original-Hörspiel zur TV-Serie)',
          'Die Zauberlimonade',
        ),
        (
          'Folge 396: Das Eisbärenjunge (Das Original-Hörspiel zur TV-Serie)',
          'Das Eisbärenjunge',
        ),
        (
          'Folge 10: Findus und das eigene Fahrrad (Das Original Hörspiel zur TV-Serie)',
          'Findus und das eigene Fahrrad',
        ),
        (
          'Folge 429: Monster-Truck-Chaos in der Abenteuerbucht (Das Original-Hörspiel zur TV-Serie)',
          'Monster-Truck-Chaos in der Abenteuerbucht',
        ),
        (
          'Brüderchen und Schwesterchen (Das Original-Hörspiel zur TV Serie)',
          'Brüderchen und Schwesterchen',
        ),
        (
          'Die Olchis im Zoo (Hörspiel)',
          'Die Olchis im Zoo',
        ),
        (
          'Das Mega-Team (Hörspiel zum Kinofilm 2017)',
          'Das Mega-Team',
        ),
        (
          'Findet Nemo (Hörspiel zum Disney/Pixar Film)',
          'Findet Nemo',
        ),
        (
          'Zoomania (Hörspiel zum Disney Film)',
          'Zoomania',
        ),
        (
          'Zoomania 2 (Hörspiel zum Disney Film)',
          'Zoomania 2',
        ),
        (
          'Zoomania+ (Hörspiel zur Disney TV-Serie)',
          'Zoomania+',
        ),
        (
          'Fünf Freunde und das Tal der Dinosaurier - Das Original-Hörspiel zum Kinofilm',
          'Fünf Freunde und das Tal der Dinosaurier - Das Original-Hörspiel zum Kinofilm',
        ),
        (
          'Erbe des Drachen (Das Original-Hörspiel zum Kinofilm)',
          'Erbe des Drachen',
        ),
        (
          'Woodwalkers (Das Original-Hörspiel zum Kinofilm)',
          'Woodwalkers',
        ),
        (
          'Findus erklärt die Welt: Tiere entdecken in Wald und Wiese (Das Original-Hörspiel zum Naturbuch)',
          'Findus erklärt die Welt: Tiere entdecken in Wald und Wiese',
        ),
      ];

      for (final (input, expected) in cases) {
        test('"$input"', () {
          // With episodeNumber: strips both Folge prefix and Hörspiel suffix.
          final result = cleanEpisodeTitle(input, episodeNumber: 1);
          expect(result, expected);
        });
      }
    });

    group('strips bracket Hörspiel suffixes', () {
      final cases = <(String, String)>[
        (
          'Bobo Siebenschläfer. Bobo besucht den Zoo und weitere Folgen (Band 1) [Original-Hörspiel zur TV-Kinderserie]',
          'Bobo Siebenschläfer. Bobo besucht den Zoo und weitere Folgen (Band 1)',
        ),
        (
          'Bobo Siebenschläfer. Bobo kann nicht einschlafen und weitere Folgen (Band 2) [Original-Hörspiel zur TV-Kinderserie]',
          'Bobo Siebenschläfer. Bobo kann nicht einschlafen und weitere Folgen (Band 2)',
        ),
      ];

      for (final (input, expected) in cases) {
        test('"${input.substring(0, 40)}..."', () {
          expect(cleanEpisodeTitle(input), expected);
        });
      }
    });

    group('strips Soundtrack suffixes', () {
      final cases = <(String, String)>[
        (
          'Bibi und Tina (Der Original-Soundtrack zum Kinofilm)',
          'Bibi und Tina',
        ),
        (
          'Bibi und Tina: VOLL VERHEXT! (Der Original-Soundtrack zum Kinofilm)',
          'Bibi und Tina: VOLL VERHEXT!',
        ),
      ];

      for (final (input, expected) in cases) {
        test('"$input"', () {
          expect(cleanEpisodeTitle(input), expected);
        });
      }
    });

    group('strips Ungekürzt/Gekürzt markers', () {
      final cases = <(String, String)>[
        ('Die Kackwurstfabrik (Ungekürzt)', 'Die Kackwurstfabrik'),
        (
          'Percy Jackson erzählt, Teil 1: Griechische Göttersagen (Gekürzt)',
          'Percy Jackson erzählt, Teil 1: Griechische Göttersagen',
        ),
      ];

      for (final (input, expected) in cases) {
        test('"$input"', () {
          expect(cleanEpisodeTitle(input), expected);
        });
      }
    });

    group('strips Folge prefix when episodeNumber provided', () {
      final cases = <(String, int, String)>[
        ('Folge 1: Hexen gibt es doch', 1, 'Hexen gibt es doch'),
        ('Folge 5: Ein verhexter Urlaub', 5, 'Ein verhexter Urlaub'),
        ('Folge 15', 15, 'Folge 15'),
        ('Folge 100: 100 Stunden', 100, '100 Stunden'),
        ('Folge 22: Das Kostüm', 22, 'Das Kostüm'),
        ('Folge 44: als Bäcker', 44, 'als Bäcker'),
        (
          'Folge 3 - Die Zauberlimonade (Das Original-Hörspiel zur TV-Serie)',
          3,
          'Die Zauberlimonade',
        ),
        (
          'Folge 1: Eine Geburtstagstorte für die Katze + zwei weitere Geschichten (Das Original-Hörspiel zur TV-Serie)',
          1,
          'Eine Geburtstagstorte für die Katze + zwei weitere Geschichten',
        ),
      ];

      for (final (input, num, expected) in cases) {
        test('"$input" (ep $num)', () {
          expect(cleanEpisodeTitle(input, episodeNumber: num), expected);
        });
      }
    });

    group('strips Episode prefix when episodeNumber provided', () {
      test('Episode 12: The Great Storm', () {
        expect(
          cleanEpisodeTitle('Episode 12: The Great Storm', episodeNumber: 12),
          'The Great Storm',
        );
      });

      test(
        '13: Kinder der Macht / Spion des Senats (Das Original-Hörspiel zur Star Wars-TV-Serie)',
        () {
          // Prefix doesn't start with "Folge" or "Episode" — should NOT strip.
          expect(
            cleanEpisodeTitle(
              '13: Kinder der Macht / Spion des Senats (Das Original-Hörspiel zur Star Wars-TV-Serie)',
              episodeNumber: 13,
            ),
            '13: Kinder der Macht / Spion des Senats',
          );
        },
      );
    });

    group('preserves Folge prefix when NO episodeNumber', () {
      test('Folge 5: Ein verhexter Urlaub', () {
        expect(
          cleanEpisodeTitle('Folge 5: Ein verhexter Urlaub'),
          'Folge 5: Ein verhexter Urlaub',
        );
      });

      test('Folge 38: Eile mit Weile (Das Original-Hörspiel zur TV-Serie)', () {
        // Suffix stripped, prefix kept (no number to show separately).
        expect(
          cleanEpisodeTitle(
            'Folge 38: Eile mit Weile (Das Original-Hörspiel zur TV-Serie)',
          ),
          'Folge 38: Eile mit Weile',
        );
      });
    });

    group('preserves meaningful parentheticals', () {
      final preserved = <String>[
        'Panik im Paradies (Die drei ??? Kids)',
        'Alles über Dinosaurier (Wieso? Weshalb? Warum? Folge 12)',
        'Die Feuerwehr (Wieso? Weshalb? Warum? JUNIOR, Folge 2)',
        'Conni auf dem Bauernhof / Conni und das neue Baby',
        'Der Räuber Hotzenplotz und die Mondrakete',
        '1: Der Räuber Hotzenplotz',
        'Jim Knopf und Lukas der Lokomotivführer',
        'Momo',
        'Oh, wie schön ist Panama',
        'Golden Heart',
        'Bobo Siebenschläfer. Großer Sommerspaß.',
        'Conni und der große Schnee',
        'Alles verzankt!, Alles zu voll!, Alles nass! (Der kleine Rabe Socke)',
        'Bobo Siebenschläfer hat Geburtstag! (Geschichten für Kleine mit KlangErlebnissen und Liedern)',
      ];

      for (final title in preserved) {
        test('"$title" unchanged', () {
          expect(cleanEpisodeTitle(title), title);
        });
      }
    });

    group('handles titles without episode number gracefully', () {
      test('plain title stays', () {
        expect(
          cleanEpisodeTitle('Der Anfang der Schlangen'),
          'Der Anfang der Schlangen',
        );
      });

      test('title with number param but no Folge prefix', () {
        expect(
          cleanEpisodeTitle('heilt den Bürgermeister', episodeNumber: 7),
          'heilt den Bürgermeister',
        );
      });
    });

    group('handles Pumuckl patterns', () {
      final cases = <(String, String)>[
        (
          '02: Pumuckl wird verschenkt (Neue Geschichten vom Pumuckl)',
          '02: Pumuckl wird verschenkt (Neue Geschichten vom Pumuckl)',
        ),
        (
          '07: Pumuckl macht Ferien (Das Original aus der Fernsehserie)',
          '07: Pumuckl macht Ferien (Das Original aus der Fernsehserie)',
        ),
        (
          'Pumuckl und das große Missverständnis (Das Original-Hörspiel zum Kinofilm) (Neue Geschichten vom Pumuckl)',
          'Pumuckl und das große Missverständnis (Das Original-Hörspiel zum Kinofilm) (Neue Geschichten vom Pumuckl)',
        ),
      ];

      for (final (input, expected) in cases) {
        test('"${input.substring(0, 30)}..."', () {
          // No episodeNumber, no Folge prefix — nothing to strip except
          // trailing Hörspiel parens. But Pumuckl's are in the middle.
          expect(cleanEpisodeTitle(input), expected);
        });
      }
    });

    group('handles number-slash format (Fünf Freunde, TKKG)', () {
      final cases = <(String, String)>[
        ('031/Rückkehr der Saurier', '031/Rückkehr der Saurier'),
        ('040/Brennendes Eis', '040/Brennendes Eis'),
        ('04/und die Einsiedlerkrebse', '04/und die Einsiedlerkrebse'),
        ('001/Bob der Küchenmeister', '001/Bob der Küchenmeister'),
      ];

      for (final (input, expected) in cases) {
        test('"$input"', () {
          expect(cleanEpisodeTitle(input), expected);
        });
      }
    });

    group('handles series.yaml Wieso Weshalb Warum style', () {
      final cases = <(String, String)>[
        (
          'Was machen wir im Frühling? (Wieso? Weshalb? Warum? JUNIOR, Folge 59)',
          'Was machen wir im Frühling? (Wieso? Weshalb? Warum? JUNIOR, Folge 59)',
        ),
        (
          'Der Kran. (Wieso? Weshalb? Warum? junior, Folge 81)',
          'Der Kran. (Wieso? Weshalb? Warum? junior, Folge 81)',
        ),
        (
          'Dinosaurier (Wieso? Weshalb? Warum? PROFIWISSEN, Folge 12)',
          'Dinosaurier (Wieso? Weshalb? Warum? PROFIWISSEN, Folge 12)',
        ),
      ];

      for (final (input, expected) in cases) {
        test('"${input.substring(0, 30)}..."', () {
          expect(cleanEpisodeTitle(input), expected);
        });
      }
    });

    group('handles Nils Holgersson / Biene Maja nested parens', () {
      final cases = <(String, int?, String)>[
        (
          'Der Adler Gorgo (Nils Holgersson, Folge 37)',
          37,
          'Der Adler Gorgo (Nils Holgersson, Folge 37)',
        ),
        (
          'Die Elfenfahrt (Die Biene Maja, Folge 13)',
          13,
          'Die Elfenfahrt (Die Biene Maja, Folge 13)',
        ),
        (
          'Das Eisenwerk (Nils Holgersson, Folge 27)',
          27,
          'Das Eisenwerk (Nils Holgersson, Folge 27)',
        ),
      ];

      for (final (input, num, expected) in cases) {
        test('"$input"', () {
          expect(cleanEpisodeTitle(input, episodeNumber: num), expected);
        });
      }
    });

    group('handles multi-episode / slash titles', () {
      final cases = <(String, int, String)>[
        (
          'Folge 11: Auf dem Flughafen / Bei der Feuerwehr',
          11,
          'Auf dem Flughafen / Bei der Feuerwehr',
        ),
        (
          'Folge 27: Tierisch tolle Schutzgeister/Voll vertauscht!',
          27,
          'Tierisch tolle Schutzgeister/Voll vertauscht!',
        ),
        (
          'Folge 45: Fall 89: Das vergeigte Konzert/Fall 90: Die springende Schildkröte',
          45,
          'Fall 89: Das vergeigte Konzert/Fall 90: Die springende Schildkröte',
        ),
        (
          'Folge 12: Wie kommen die Babys auf die Welt? / Was mein Körper alles kann',
          12,
          'Wie kommen die Babys auf die Welt? / Was mein Körper alles kann',
        ),
      ];

      for (final (input, num, expected) in cases) {
        test('"${input.substring(0, 40)}..." (ep $num)', () {
          expect(cleanEpisodeTitle(input, episodeNumber: num), expected);
        });
      }
    });

    group('edge cases', () {
      test('empty string returns empty string', () {
        expect(cleanEpisodeTitle(''), '');
      });

      test('Folge N with no colon/dash and episodeNumber keeps original', () {
        // "Folge 15" has no separator — nothing to strip to.
        expect(cleanEpisodeTitle('Folge 15', episodeNumber: 15), 'Folge 15');
      });

      test('only suffix → falls back to original', () {
        expect(
          cleanEpisodeTitle('(Das Original-Hörspiel zur TV-Serie)'),
          '(Das Original-Hörspiel zur TV-Serie)',
        );
      });

      test('Staffel prefix preserved', () {
        expect(
          cleanEpisodeTitle(
            'Staffel 2: Die neuen Abenteuer von Bobo (Das Hörspiel zur Kinder TV- Serie)',
          ),
          'Staffel 2: Die neuen Abenteuer von Bobo',
        );
      });
    });
  });
}
