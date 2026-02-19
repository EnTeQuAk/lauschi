import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/catalog/catalog_service.dart';

// Album names in this file are real titles taken from the Spotify API
// (cached in .cache/spotify_catalog/) so the patterns stay grounded in reality.

void main() {
  late CatalogService catalog;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    catalog = await CatalogService.load();
  });

  group('CatalogService.load', () {
    test('loads at least 45 series', () {
      expect(catalog.seriesCount, greaterThanOrEqualTo(45));
    });
  });

  group('CatalogService.match — null / noise', () {
    test('returns null for unknown content', () {
      expect(catalog.match('Random Pop Album 2024'), isNull);
    });

    test('returns null for empty string', () {
      expect(catalog.match(''), isNull);
    });

    test('does not match "Samsara Davanala" as Das Sams', () {
      // Old keyword "sams" was too short; now requires "das sams".
      expect(catalog.match('Samsara Davanala'), isNull);
    });

    test('does not extract year as episode (noise veto)', () {
      // Wickie compilation title — should not produce episode 1974.
      final r = catalog.match(
          'Wickie 1974-2009 (Original Soundtrack Zur TV-Serie 1974)');
      // May or may not match keyword, but if it does, episode must not be 1974.
      if (r != null) {
        expect(r.episodeNumber, isNot(1974));
      }
    });
  });

  group('CatalogService.match — series identity', () {
    test('matches Yakari by keyword', () {
      final r = catalog.match(
          'Folge 9: Yakari und die Pferdediebe (Das Original-Hörspiel zur TV-Serie)');
      expect(r, isNotNull);
      expect(r!.series.id, 'yakari');
    });

    test('matches Bibi Blocksberg', () {
      final r = catalog.match('Folge 157: Team Blocksberg');
      // keyword "blocksberg" must fire
      expect(r, isNotNull);
      expect(r!.series.id, 'bibi_blocksberg');
    });

    test('matches Benjamin Blümchen case-insensitively', () {
      final r = catalog.match('benjamin blümchen - sonderedition');
      expect(r, isNotNull);
      expect(r!.series.id, 'benjamin_bluemchen');
    });

    test('matches Die drei ???', () {
      final r = catalog.match('Die drei ??? und der Karpatenhund');
      expect(r, isNotNull);
      expect(r!.series.id, 'die_drei_fragezeichen');
    });

    test('prefers Die drei ??? Kids over Die drei ??? (more specific keyword)', () {
      final r = catalog.match('Die drei ??? Kids, Folge 30');
      expect(r, isNotNull);
      expect(r!.series.id, 'die_drei_fragezeichen_kids');
    });

    test('matches TKKG by keyword', () {
      final r = catalog.match('Das Geheimnis um TKKG (Neuaufnahme)');
      expect(r, isNotNull);
      expect(r!.series.id, 'tkkg');
    });

    test('matches Bibi & Tina by keyword', () {
      final r = catalog.match('Bibi und Tina: VOLL VERHEXT! (Der Original-Soundtrack zum Kinofilm)');
      expect(r, isNotNull);
      expect(r!.series.id, 'bibi_und_tina');
    });

    test('matches Pumuckl by keyword', () {
      final r = catalog.match('19: Pumuckl im Zoo (Das Original aus dem Fernsehen)');
      expect(r, isNotNull);
      expect(r!.series.id, 'pumuckl');
    });

    test('matches Conni by keyword (standalone, no episode)', () {
      final r = catalog.match('Conni rettet Oma');
      expect(r, isNotNull);
      expect(r!.series.id, 'conni');
      expect(r.episodeNumber, isNull);
    });

    test('matches Pippi Langstrumpf', () {
      final r = catalog.match('Pippi Langstrumpf 1. Das Hörspiel');
      expect(r, isNotNull);
      expect(r!.series.id, 'pippi_langstrumpf');
    });

    test('matches Pettersson und Findus', () {
      final r = catalog.match(
          'Folge 10: Findus und das eigene Fahrrad (Das Original Hörspiel zur TV-Serie)');
      expect(r, isNotNull);
      expect(r!.series.id, 'pettersson_und_findus');
    });

    test('matches Das Sams', () {
      final r = catalog.match('Das Sams 1. Eine Woche voller Samstage');
      expect(r, isNotNull);
      expect(r!.series.id, 'das_sams');
    });

    test('matches Biene Maja', () {
      final r = catalog.match('Majas Flucht aus der Heimatstadt (Die Biene Maja, Folge 1)');
      expect(r, isNotNull);
      expect(r!.series.id, 'biene_maja');
    });

    test('matches Hui Buh', () {
      final r = catalog.match('01/Hui Buh das Schlossgespenst');
      expect(r, isNotNull);
      expect(r!.series.id, 'hui_buh');
    });

    test('matches Räuber Hotzenplotz', () {
      final r = catalog.match('Der Räuber Hotzenplotz 1: Der Räuber Hotzenplotz');
      expect(r, isNotNull);
      expect(r!.series.id, 'raeubrer_hotzenplotz');
    });

    test('matches Der kleine Drache Kokosnuss (no episode)', () {
      final r = catalog.match('Der kleine Drache Kokosnuss - Das Musical');
      expect(r, isNotNull);
      expect(r!.series.id, 'kleiner_drache_kokosnuss');
      expect(r.episodeNumber, isNull);
    });

    test('matches Hanni und Nanni', () {
      final r = catalog.match('065/Hanni und Nanni voll im Trend!');
      expect(r, isNotNull);
      expect(r!.series.id, 'hanni_und_nanni');
    });

    test('matches Lauras Stern', () {
      final r = catalog.match('Lauras Stern, Folge 1: Lauras Stern');
      expect(r, isNotNull);
      expect(r!.series.id, 'lauras_stern');
    });

    test('matches Tom Turbo', () {
      final r = catalog.match(
          'Familie Vogel fragt: Wie läuft eine Reise am Flughafen ab? (Wissensreise mit Tom Turbo! Teil 1)');
      expect(r, isNotNull);
      expect(r!.series.id, 'tom_turbo');
    });

    test('matches Nils Holgersson', () {
      final r = catalog.match('Der Junge (Nils Holgersson, Folge 1)');
      expect(r, isNotNull);
      expect(r!.series.id, 'nils_holgersson');
    });

    test('matches Heidi', () {
      final r = catalog.match('06/Heidi kehrt zurück');
      expect(r, isNotNull);
      expect(r!.series.id, 'heidi');
    });

    test('matches Die Fuchsbande by keyword', () {
      // The only album whose title contains "fuchsbande".
      final r = catalog.match(
          'Singt alle mit! Bekannte Kinderlieder in der Fuchsbande-Version');
      expect(r, isNotNull);
      expect(r!.series.id, 'die_fuchsbande');
    });

    test('matches Die Playmos', () {
      final r = catalog.match(
          'Folge 46: Die Playmos ermitteln (Das Original Playmobil Hörspiel)');
      expect(r, isNotNull);
      expect(r!.series.id, 'die_playmos');
    });

    test('matches Wendy', () {
      final r = catalog.match('Folge 22: Wendy verliebt sich');
      expect(r, isNotNull);
      expect(r!.series.id, 'wendy');
    });

    test('matches Asterix', () {
      final r = catalog.match('41: Asterix in Lusitanien');
      expect(r, isNotNull);
      expect(r!.series.id, 'asterix');
    });

    test('matches Momo as Michael Ende', () {
      final r = catalog.match('Momo - Michael Ende');
      expect(r, isNotNull);
      expect(r!.series.id, 'michael_ende');
    });

    test('matches Jim Knopf as Michael Ende', () {
      final r = catalog.match('Jim Knopf und Lukas der Lokomotivführer');
      expect(r, isNotNull);
      expect(r!.series.id, 'michael_ende');
    });

    test('matches Gespensterjäger', () {
      final r = catalog.match('Gespensterjäger auf eisiger Spur (Band 1)');
      expect(r, isNotNull);
      expect(r!.series.id, 'gespensterjager');
    });

    test('matches LasseMaja', () {
      final r = catalog.match('Detektivbüro LasseMaja 1');
      expect(r, isNotNull);
      expect(r!.series.id, 'lassemaja');
    });
  });

  group('CatalogService.match — episode number extraction', () {
    // Yakari: "Folge N:" format
    test('Yakari extracts Folge N', () {
      final r = catalog.match(
          'Folge 9: Yakari und die Pferdediebe (Das Original-Hörspiel zur TV-Serie)');
      expect(r!.episodeNumber, 9);
    });

    test('Yakari extracts larger Folge N', () {
      final r = catalog.match(
          'Folge 33: Yakari und Silberfell (Das Original-Hörspiel zur TV-Serie)');
      expect(r!.episodeNumber, 33);
    });

    // Bibi Blocksberg: "Folge N:" format
    test('Bibi Blocksberg extracts Folge N', () {
      final r = catalog.match('Folge 157: Team Blocksberg');
      expect(r!.episodeNumber, 157);
    });

    // Pumuckl: "NN: title" leading number format
    test('Pumuckl extracts leading NN: number', () {
      final r = catalog.match('19: Pumuckl im Zoo (Das Original aus dem Fernsehen)');
      expect(r!.episodeNumber, 19);
    });

    test('Pumuckl extracts zero-padded number', () {
      final r = catalog.match('06: Pumuckl und die Schule (Das Original aus dem Fernsehen)');
      expect(r!.episodeNumber, 6);
    });

    // Hanni und Nanni: three formats
    test('Hanni und Nanni extracts NNN/ prefix', () {
      final r = catalog.match('065/Hanni und Nanni voll im Trend!');
      expect(r!.episodeNumber, 65);
    });

    test('Hanni und Nanni extracts short NN/ prefix', () {
      final r = catalog.match('04/Lustige Streiche mit Hanni und Nanni');
      expect(r!.episodeNumber, 4);
    });

    test('Hanni und Nanni extracts Folge N:', () {
      final r = catalog.match('Folge 79: Prost Neujahr, Hanni und Nanni!');
      expect(r!.episodeNumber, 79);
    });

    test('Hanni und Nanni extracts Klassiker N', () {
      final r = catalog.match('Klassiker 1 - 1972 Hanni und Nanni sind immer dagegen');
      expect(r!.episodeNumber, 1);
    });

    // Räuber Hotzenplotz: both publisher formats
    test('Räuber Hotzenplotz extracts from "Der Räuber Hotzenplotz N:" format', () {
      final r = catalog.match('Der Räuber Hotzenplotz 1: Der Räuber Hotzenplotz');
      expect(r!.episodeNumber, 1);
    });

    test('Räuber Hotzenplotz extracts from leading "N: title" format', () {
      final r = catalog.match('1: Der Räuber Hotzenplotz');
      expect(r!.episodeNumber, 1);
    });

    test('Räuber Hotzenplotz extracts from leading "2: Neues..." format', () {
      final r = catalog.match('2: Neues vom Räuber Hotzenplotz');
      expect(r!.episodeNumber, 2);
    });

    // Hui Buh: NNN/ and Folge N: formats
    test('Hui Buh extracts NNN/ prefix', () {
      final r = catalog.match('01/Hui Buh das Schlossgespenst');
      expect(r!.episodeNumber, 1);
    });

    test('Hui Buh extracts 3-digit NNN/ prefix', () {
      final r = catalog.match('002/Hui Buh und seine Rasselkette/Halloween-Party');
      expect(r!.episodeNumber, 2);
    });

    test('Hui Buh extracts Folge N:', () {
      final r = catalog.match('Folge 18: Hui Buh rettet Halloween');
      expect(r!.episodeNumber, 18);
    });

    // Pippi Langstrumpf: "Pippi Langstrumpf N. title" format
    test('Pippi Langstrumpf extracts book number', () {
      final r = catalog.match('Pippi Langstrumpf 1. Das Hörspiel');
      expect(r!.episodeNumber, 1);
    });

    test('Pippi Langstrumpf extracts book number 3', () {
      final r = catalog.match('Pippi Langstrumpf 3. Pippi in Taka-Tuka-Land. Das Hörspiel');
      expect(r!.episodeNumber, 3);
    });

    // Das Sams: "Das Sams N. title" format
    test('Das Sams extracts book number', () {
      final r = catalog.match('Das Sams 1. Eine Woche voller Samstage');
      expect(r!.episodeNumber, 1);
    });

    test('Das Sams extracts book number 3', () {
      final r = catalog.match('Das Sams 3. Neue Punkte für das Sams');
      expect(r!.episodeNumber, 3);
    });

    // Biene Maja: "Biene Maja, Folge N" format
    test('Biene Maja extracts Folge N', () {
      final r = catalog.match('Majas Flucht aus der Heimatstadt (Die Biene Maja, Folge 1)');
      expect(r!.episodeNumber, 1);
    });

    // Nils Holgersson: series name before OR after Folge
    test('Nils Holgersson extracts from "Series, Folge N" format', () {
      final r = catalog.match('Der Junge (Nils Holgersson, Folge 1)');
      expect(r!.episodeNumber, 1);
    });

    test('Nils Holgersson extracts from "Folge N: title" format', () {
      final r = catalog.match(
          'Folge 1: Die wunderbare Reise des kleinen Nils Holgersson mit den Wildgänsen');
      expect(r!.episodeNumber, 1);
    });

    test('Nils Holgersson extracts from "Märchenklassiker Folge N"', () {
      final r = catalog.match('Nils Holgersson - Märchenklassiker Folge 7');
      expect(r!.episodeNumber, 7);
    });

    // Heidi: NNN/ prefix format
    test('Heidi extracts NN/ prefix', () {
      final r = catalog.match('06/Heidi kehrt zurück');
      expect(r!.episodeNumber, 6);
    });

    test('Heidi extracts NNN/ prefix', () {
      final r = catalog.match('068/Heidi I');
      expect(r!.episodeNumber, 68);
    });

    // Tom Turbo: "Teil N" format
    test('Tom Turbo extracts Teil N', () {
      final r = catalog.match(
          'Familie Vogel fragt: Wie läuft eine Reise am Flughafen ab? (Wissensreise mit Tom Turbo! Teil 1)');
      expect(r!.episodeNumber, 1);
    });

    test('Tom Turbo extracts Teil N (larger)', () {
      final r = catalog.match(
          'Familie Vogel fragt: Klettern Ziegen auf Bäume? (Wissensreise mit Tom Turbo! Teil 10)');
      expect(r!.episodeNumber, 10);
    });

    // Lauras Stern: Folge N and Band N
    test('Lauras Stern extracts Folge N', () {
      final r = catalog.match('Lauras Stern, Folge 1: Lauras Stern');
      expect(r!.episodeNumber, 1);
    });

    test('Lauras Stern extracts trailing number in brackets', () {
      // "Lauras Stern 10 (Ungekürzt)"
      final r = catalog.match('Laura hat Geburtstag [Lauras Stern 10 (Ungekürzt)]');
      expect(r!.episodeNumber, 10);
    });

    test('Lauras Stern extracts Band N', () {
      final r = catalog.match('Lauras Stern, Band 12: Freundschaftliche Gutenacht-Geschichten');
      expect(r!.episodeNumber, 12);
    });

    // Pettersson und Findus: "Folge N:" format
    test('Pettersson und Findus extracts Folge N', () {
      final r = catalog.match(
          'Folge 10: Findus und das eigene Fahrrad (Das Original Hörspiel zur TV-Serie)');
      expect(r!.episodeNumber, 10);
    });

    // Die Playmos: "Folge N:" format
    test('Die Playmos extracts Folge N', () {
      final r = catalog.match(
          'Folge 46: Die Playmos ermitteln (Das Original Playmobil Hörspiel)');
      expect(r!.episodeNumber, 46);
    });

    test('Die Playmos extracts single-digit Folge N', () {
      final r = catalog.match(
          'Folge 9: Manege frei für die Playmos (Das Original Playmobil Hörspiel)');
      expect(r!.episodeNumber, 9);
    });

    // Wendy: Folge N and NNN/ formats
    test('Wendy extracts Folge N', () {
      final r = catalog.match('Folge 22: Wendy verliebt sich');
      expect(r!.episodeNumber, 22);
    });

    test('Wendy extracts NNN/ prefix', () {
      final r = catalog.match('005/Wendy Wolf hat Geburtstag (und 5 weitere Geschichten)');
      expect(r!.episodeNumber, 5);
    });

    // Asterix: "NN: title" format
    test('Asterix extracts leading NN: number', () {
      final r = catalog.match('41: Asterix in Lusitanien');
      expect(r!.episodeNumber, 41);
    });

    test('Asterix extracts zero-padded number', () {
      final r = catalog.match('02: Asterix und Kleopatra');
      expect(r!.episodeNumber, 2);
    });

    // Gespensterjäger: Band N and Folge N formats
    test('Gespensterjäger extracts Band N from parentheses', () {
      final r = catalog.match('Gespensterjäger auf eisiger Spur (Band 1)');
      expect(r!.episodeNumber, 1);
    });

    test('Gespensterjäger extracts Band N without parentheses', () {
      final r = catalog.match('Gespensterjäger im Feuerspuk (Band 2)');
      expect(r!.episodeNumber, 2);
    });

    test('Gespensterjäger extracts Folge N', () {
      final r = catalog.match('Folge 5: Gespensterjäger und der Weihnachtsspuk');
      expect(r!.episodeNumber, 5);
    });

    test('Gespensterjäger extracts NN/ prefix', () {
      final r = catalog.match('04/Der Schatten des Gespensterjägers');
      expect(r!.episodeNumber, 4);
    });

    // LasseMaja: well-covered, spot check
    test('LasseMaja extracts episode number', () {
      final r = catalog.match('Detektivbüro LasseMaja 1');
      expect(r!.episodeNumber, 1);
    });
  });
}
