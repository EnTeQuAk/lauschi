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
        'Wickie 1974-2009 (Original Soundtrack Zur TV-Serie 1974)',
      );
      // May or may not match keyword, but if it does, episode must not be 1974.
      if (r != null) {
        expect(r.episodeNumber, isNot(1974));
      }
    });
  });

  group('CatalogService.match — series identity', () {
    test('matches Yakari by keyword', () {
      final r = catalog.match(
        'Folge 9: Yakari und die Pferdediebe (Das Original-Hörspiel zur TV-Serie)',
      );
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

    test(
      'prefers Die drei ??? Kids over Die drei ??? (more specific keyword)',
      () {
        final r = catalog.match('Die drei ??? Kids, Folge 30');
        expect(r, isNotNull);
        expect(r!.series.id, 'die_drei_fragezeichen_kids');
      },
    );

    test('matches TKKG by keyword', () {
      final r = catalog.match('Das Geheimnis um TKKG (Neuaufnahme)');
      expect(r, isNotNull);
      expect(r!.series.id, 'tkkg');
    });

    test('matches Bibi & Tina by keyword', () {
      final r = catalog.match(
        'Bibi und Tina: VOLL VERHEXT! (Der Original-Soundtrack zum Kinofilm)',
      );
      expect(r, isNotNull);
      expect(r!.series.id, 'bibi_und_tina');
    });

    test('matches Pumuckl by keyword', () {
      final r = catalog.match(
        '19: Pumuckl im Zoo (Das Original aus dem Fernsehen)',
      );
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
        'Folge 10: Findus und das eigene Fahrrad (Das Original Hörspiel zur TV-Serie)',
      );
      expect(r, isNotNull);
      expect(r!.series.id, 'pettersson_und_findus');
    });

    test('matches Das Sams', () {
      final r = catalog.match('Das Sams 1. Eine Woche voller Samstage');
      expect(r, isNotNull);
      expect(r!.series.id, 'das_sams');
    });

    test('matches Biene Maja', () {
      final r = catalog.match(
        'Majas Flucht aus der Heimatstadt (Die Biene Maja, Folge 1)',
      );
      expect(r, isNotNull);
      expect(r!.series.id, 'biene_maja');
    });

    test('matches Hui Buh', () {
      final r = catalog.match('01/Hui Buh das Schlossgespenst');
      expect(r, isNotNull);
      expect(r!.series.id, 'hui_buh');
    });

    test('matches Räuber Hotzenplotz', () {
      final r = catalog.match(
        'Der Räuber Hotzenplotz 1: Der Räuber Hotzenplotz',
      );
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
        'Familie Vogel fragt: Wie läuft eine Reise am Flughafen ab? (Wissensreise mit Tom Turbo! Teil 1)',
      );
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
        'Singt alle mit! Bekannte Kinderlieder in der Fuchsbande-Version',
      );
      expect(r, isNotNull);
      expect(r!.series.id, 'die_fuchsbande');
    });

    test('matches Die Playmos', () {
      final r = catalog.match(
        'Folge 46: Die Playmos ermitteln (Das Original Playmobil Hörspiel)',
      );
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
        'Folge 9: Yakari und die Pferdediebe (Das Original-Hörspiel zur TV-Serie)',
      );
      expect(r!.episodeNumber, 9);
    });

    test('Yakari extracts larger Folge N', () {
      final r = catalog.match(
        'Folge 33: Yakari und Silberfell (Das Original-Hörspiel zur TV-Serie)',
      );
      expect(r!.episodeNumber, 33);
    });

    // Bibi Blocksberg: "Folge N:" format
    test('Bibi Blocksberg extracts Folge N', () {
      final r = catalog.match('Folge 157: Team Blocksberg');
      expect(r!.episodeNumber, 157);
    });

    // Pumuckl: "NN: title" leading number format
    test('Pumuckl extracts leading NN: number', () {
      final r = catalog.match(
        '19: Pumuckl im Zoo (Das Original aus dem Fernsehen)',
      );
      expect(r!.episodeNumber, 19);
    });

    test('Pumuckl extracts zero-padded number', () {
      final r = catalog.match(
        '06: Pumuckl und die Schule (Das Original aus dem Fernsehen)',
      );
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
      final r = catalog.match(
        'Klassiker 1 - 1972 Hanni und Nanni sind immer dagegen',
      );
      expect(r!.episodeNumber, 1);
    });

    // Räuber Hotzenplotz: both publisher formats
    test(
      'Räuber Hotzenplotz extracts from "Der Räuber Hotzenplotz N:" format',
      () {
        final r = catalog.match(
          'Der Räuber Hotzenplotz 1: Der Räuber Hotzenplotz',
        );
        expect(r!.episodeNumber, 1);
      },
    );

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
      final r = catalog.match(
        '002/Hui Buh und seine Rasselkette/Halloween-Party',
      );
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
      final r = catalog.match(
        'Pippi Langstrumpf 3. Pippi in Taka-Tuka-Land. Das Hörspiel',
      );
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
      final r = catalog.match(
        'Majas Flucht aus der Heimatstadt (Die Biene Maja, Folge 1)',
      );
      expect(r!.episodeNumber, 1);
    });

    // Nils Holgersson: series name before OR after Folge
    test('Nils Holgersson extracts from "Series, Folge N" format', () {
      final r = catalog.match('Der Junge (Nils Holgersson, Folge 1)');
      expect(r!.episodeNumber, 1);
    });

    test('Nils Holgersson extracts from "Folge N: title" format', () {
      final r = catalog.match(
        'Folge 1: Die wunderbare Reise des kleinen Nils Holgersson mit den Wildgänsen',
      );
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
        'Familie Vogel fragt: Wie läuft eine Reise am Flughafen ab? (Wissensreise mit Tom Turbo! Teil 1)',
      );
      expect(r!.episodeNumber, 1);
    });

    test('Tom Turbo extracts Teil N (larger)', () {
      final r = catalog.match(
        'Familie Vogel fragt: Klettern Ziegen auf Bäume? (Wissensreise mit Tom Turbo! Teil 10)',
      );
      expect(r!.episodeNumber, 10);
    });

    // Lauras Stern: Folge N and Band N
    test('Lauras Stern extracts Folge N', () {
      final r = catalog.match('Lauras Stern, Folge 1: Lauras Stern');
      expect(r!.episodeNumber, 1);
    });

    test('Lauras Stern extracts trailing number in brackets', () {
      // "Lauras Stern 10 (Ungekürzt)"
      final r = catalog.match(
        'Laura hat Geburtstag [Lauras Stern 10 (Ungekürzt)]',
      );
      expect(r!.episodeNumber, 10);
    });

    test('Lauras Stern extracts Band N', () {
      final r = catalog.match(
        'Lauras Stern, Band 12: Freundschaftliche Gutenacht-Geschichten',
      );
      expect(r!.episodeNumber, 12);
    });

    // Pettersson und Findus: "Folge N:" format
    test('Pettersson und Findus extracts Folge N', () {
      final r = catalog.match(
        'Folge 10: Findus und das eigene Fahrrad (Das Original Hörspiel zur TV-Serie)',
      );
      expect(r!.episodeNumber, 10);
    });

    // Die Playmos: "Folge N:" format
    test('Die Playmos extracts Folge N', () {
      final r = catalog.match(
        'Folge 46: Die Playmos ermitteln (Das Original Playmobil Hörspiel)',
      );
      expect(r!.episodeNumber, 46);
    });

    test('Die Playmos extracts single-digit Folge N', () {
      final r = catalog.match(
        'Folge 9: Manege frei für die Playmos (Das Original Playmobil Hörspiel)',
      );
      expect(r!.episodeNumber, 9);
    });

    // Wendy: Folge N and NNN/ formats
    test('Wendy extracts Folge N', () {
      final r = catalog.match('Folge 22: Wendy verliebt sich');
      expect(r!.episodeNumber, 22);
    });

    test('Wendy extracts NNN/ prefix', () {
      final r = catalog.match(
        '005/Wendy Wolf hat Geburtstag (und 5 weitere Geschichten)',
      );
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
      final r = catalog.match(
        'Folge 5: Gespensterjäger und der Weihnachtsspuk',
      );
      expect(r!.episodeNumber, 5);
    });

    test('Gespensterjäger extracts NN/ prefix', () {
      final r = catalog.match('04/Der Schatten des Gespensterjägers');
      expect(r!.episodeNumber, 4);
    });

    // LasseMaja: well-covered, spot check
    test('LasseMaja extracts episode number', () {
      // Real Spotify format: "Das Dinogeheimnis [Detektivbüro LasseMaja, Teil 36 (Ungekürzt)]"
      final r = catalog.match(
        'Das Dinogeheimnis [Detektivbüro LasseMaja, Teil 36 (Ungekürzt)]',
      );
      expect(r!.episodeNumber, 36);
    });
  });

  group('CatalogService.match — artist ID (phase 2)', () {
    // Albums whose titles contain no series name — only artist ID can identify them.
    // These real formats are structural failures for keyword matching.

    test(
      'Die drei ??? matched via artist ID when title has no series name',
      () {
        // Real Spotify album: "116/Codename: Cobra"
        const dreiId = '3meJIgRw7YleJrmbpbJK6S';
        final r = catalog.match(
          '116/Codename: Cobra',
          albumArtistIds: [dreiId],
        );
        expect(r, isNotNull);
        expect(r!.series.id, 'die_drei_fragezeichen');
        expect(r.source, CatalogMatchSource.artistId);
        expect(r.episodeNumber, 116);
      },
    );

    test('TKKG matched via artist ID when title has no series name', () {
      // Real Spotify album: "140/Draculas Erben"
      const tkkgId = '61qDotnjM0jnY5lkfOP7ve';
      final r = catalog.match(
        '140/Draculas Erben',
        albumArtistIds: [tkkgId],
      );
      expect(r, isNotNull);
      expect(r!.series.id, 'tkkg');
      expect(r.source, CatalogMatchSource.artistId);
      expect(r.episodeNumber, 140);
    });

    test('Die Fuchsbande matched via artist ID — Fall N extracted', () {
      // Real Spotify album: "010/Fall 19: Das Loch in der Tür"
      const fuchsId = '325gkGGHH2WrswRh3qC3e9';
      final r = catalog.match(
        '010/Fall 19: Das Loch in der Tür',
        albumArtistIds: [fuchsId],
      );
      expect(r, isNotNull);
      expect(r!.series.id, 'die_fuchsbande');
      expect(r.source, CatalogMatchSource.artistId);
      expect(r.episodeNumber, 10); // album number prefix, not Fall 19
    });

    test('Fünf Freunde matched via artist ID', () {
      // Real Spotify album: "107/und die Nacht im Safari-Park"
      const ffId = '1hD52edfn6aNsK3fb5c2OT';
      final r = catalog.match(
        '107/und die Nacht im Safari-Park',
        albumArtistIds: [ffId],
      );
      expect(r, isNotNull);
      expect(r!.series.id, 'fuenf_freunde');
      expect(r.source, CatalogMatchSource.artistId);
      expect(r.episodeNumber, 107);
    });

    test('TKKG Junior matched via artist ID', () {
      // Real Spotify album: "Folge 41: Aliens im Anflug" — series name absent
      const tkkgJuniorId = '1ZFGYimyLnfKewOL84ABEp';
      final r = catalog.match(
        'Folge 41: Aliens im Anflug',
        albumArtistIds: [tkkgJuniorId],
      );
      expect(r, isNotNull);
      expect(r!.series.id, 'tkkg_junior');
      expect(r.source, CatalogMatchSource.artistId);
      expect(r.episodeNumber, 41);
    });

    test('Feuerwehrmann Sam matched via artist ID', () {
      // "Folge 242: Die neue Feuerwache" — "Sam" alone is not a keyword
      const samId = '4qhaHyCtCaFugTqT9LzuKp';
      final r = catalog.match(
        'Folge 242: Die neue Feuerwache',
        albumArtistIds: [samId],
      );
      expect(r, isNotNull);
      expect(r!.series.id, 'feuerwehrmann_sam');
      expect(r.source, CatalogMatchSource.artistId);
      expect(r.episodeNumber, 242);
    });

    test('artist ID match does NOT fire when albumArtistIds is empty', () {
      // Without artist IDs, "116/Codename: Cobra" has no keywords to match.
      final r = catalog.match('116/Codename: Cobra');
      expect(r, isNull);
    });

    test('keyword match has source=keyword', () {
      final r = catalog.match('Folge 157: Team Blocksberg');
      expect(r, isNotNull);
      expect(r!.source, CatalogMatchSource.keyword);
    });

    test('keyword match wins over artist ID match for same series', () {
      // Album has both keyword AND artist ID — should match via keyword (phase 1).
      const bibiId = '3t2iKODSDyzoDJw7AsD99u';
      final r = catalog.match(
        'Folge 157: Team Blocksberg',
        albumArtistIds: [bibiId],
      );
      expect(r, isNotNull);
      expect(r!.series.id, 'bibi_blocksberg');
      expect(r.source, CatalogMatchSource.keyword);
    });

    test('unknown artist ID does not match any series', () {
      final r = catalog.match(
        'Some Random Album Title',
        albumArtistIds: ['0000000000000000000000'],
      );
      expect(r, isNull);
    });
  });

  group('CatalogService.match — new series (2026-02-19 additions)', () {
    test('Die Schule der magischen Tiere matches by keyword', () {
      final r = catalog.match(
        'Die Schule der magischen Tiere - Das Hörbuch zum Film',
      );
      expect(r, isNotNull);
      expect(r!.series.id, 'schule_magische_tiere');
    });

    test('Die Schule der magischen Tiere matches by artist ID', () {
      const id = '1BElEHaU2xaZg7FOGsSird';
      final r = catalog.match('Irgendein Titel', albumArtistIds: [id]);
      expect(r, isNotNull);
      expect(r!.series.id, 'schule_magische_tiere');
      expect(r.source, CatalogMatchSource.artistId);
    });

    test('Globi matches by keyword', () {
      final r = catalog.match('Globi und der Kobold');
      expect(r, isNotNull);
      expect(r!.series.id, 'globi');
    });

    test('Was ist Was matches by keyword', () {
      final r = catalog.match('Was Ist Was - Vulkane und Erdbeben');
      expect(r, isNotNull);
      expect(r!.series.id, 'was_ist_was');
    });

    test('Wieso Weshalb Warum matches by keyword', () {
      final r = catalog.match('Wieso? Weshalb? Warum? - Wie entstehen Wolken?');
      expect(r, isNotNull);
      expect(r!.series.id, 'wieso_weshalb_warum');
    });

    test('Leo Lausemaus matches by keyword', () {
      final r = catalog.match('Leo Lausemaus und die Zahnfee');
      expect(r, isNotNull);
      expect(r!.series.id, 'leo_lausemaus');
    });

    test('Bobo Siebenschläfer matches by keyword', () {
      final r = catalog.match('Bobo Siebenschläfer entdeckt die Welt');
      expect(r, isNotNull);
      expect(r!.series.id, 'bobo_siebenschlaefer');
    });

    test('Der kleine Rabe Socke matches by keyword', () {
      final r = catalog.match(
        'Der Kleine Rabe Socke - Das Hörbuch zum Kinofilm',
      );
      expect(r, isNotNull);
      expect(r!.series.id, 'der_kleine_rabe_socke');
    });

    test('Peppa Wutz matches by keyword', () {
      final r = catalog.match('Peppa Wutz - Peppa feiert Weihnachten');
      expect(r, isNotNull);
      expect(r!.series.id, 'peppa_wutz');
    });

    test('Sandmännchen matches by keyword', () {
      final r = catalog.match('Unser Sandmännchen - Gute-Nacht-Geschichten');
      expect(r, isNotNull);
      expect(r!.series.id, 'sandmaennchen');
    });

    test('Tabaluga matches by keyword', () {
      final r = catalog.match('Tabaluga und das leuchtende Eis');
      expect(r, isNotNull);
      expect(r!.series.id, 'tabaluga');
    });

    test('Die wilden Hühner matches by keyword', () {
      final r = catalog.match('Die Wilden Hühner - Hörspiel zum Film');
      expect(r, isNotNull);
      expect(r!.series.id, 'die_wilden_huehner');
    });
  });

  group('CatalogService.match — alias fixes (2026-02-19 review)', () {
    test('Bullerbü matches via "Wir Kinder aus Bullerbü" alias keyword', () {
      final r = catalog.match('Wir Kinder aus Bullerbü - Das Hörspiel');
      expect(r, isNotNull);
      expect(r!.series.id, 'bullerbue');
    });

    test(
      'Gespensterjäger: "Geisterjäger" does NOT match (wrong alias removed)',
      () {
        // "Geisterjäger" is a different word; was previously a wrong alias
        final r = catalog.match('Geisterjäger im Sturm');
        expect(r?.series.id, isNot('gespensterjager'));
      },
    );

    test('Pumuckl matches via "meister eder" keyword', () {
      final r = catalog.match(
        'Meister Eder und sein Pumuckl - Die Hörspielkassette',
      );
      expect(r, isNotNull);
      expect(r!.series.id, 'pumuckl');
    });

    test('Pippi matches Swedish spelling pippi långstrump', () {
      final r = catalog.match('Pippi Långstrump på de sju haven (Hörspiel)');
      expect(r, isNotNull);
      expect(r!.series.id, 'pippi_langstrumpf');
    });
  });

  group('CatalogService — extractEpisode direction (left-to-right)', () {
    // Verifies group priority in alternation patterns (Opus finding: left-to-right wins)

    test('Die drei ??? NNN/ format preferred over null Folge group', () {
      // Pattern: (?:^(\d{1,3})/|[Ff]olge\s+(\d+))
      // "116/Codename: Cobra" — group 1 fires (NNN/), group 2 is null
      const id = '3meJIgRw7YleJrmbpbJK6S';
      final r = catalog.match('116/Codename: Cobra', albumArtistIds: [id]);
      expect(r!.episodeNumber, 116); // group 1 wins
    });

    test('Die drei ??? Folge N format when no NNN/ prefix', () {
      // "Folge 227: Melodie" — group 1 null, group 2 fires
      const id = '3meJIgRw7YleJrmbpbJK6S';
      final r = catalog.match(
        'Folge 227: Melodie der Rache',
        albumArtistIds: [id],
      );
      expect(r!.episodeNumber, 227); // group 2 wins (group 1 null)
    });

    test('Hanni und Nanni: NNN/ preferred over Folge N when both present', () {
      // Pattern: (?:^(\d{1,3})/|[Ff]olge\s+(\d+)|[Kk]lassiker\s+(\d+))
      // With left-to-right: "065/Hanni und Nanni" → group 1 (065=65) wins
      final r = catalog.match('065/Hanni und Nanni voll im Trend!');
      expect(r!.episodeNumber, 65);
    });
  });

  group('CatalogService — catalog albums', () {
    test('series with curated albums exposes them', () {
      final bb = catalog.all.where((s) => s.id == 'benjamin_bluemchen').first;
      expect(bb.hasCuratedAlbums, isTrue);
      expect(bb.albums.length, greaterThan(100));
      expect(bb.albums.first.spotifyId, isNotEmpty);
      expect(bb.albums.first.title, contains('Folge'));
      expect(bb.albums.first.episode, 1);
      expect(bb.albums.first.uri, startsWith('spotify:album:'));
    });

    test('series without curated albums has empty list', () {
      final ddf =
          catalog.all.where((s) => s.id == 'die_drei_fragezeichen').first;
      expect(ddf.hasCuratedAlbums, isFalse);
      expect(ddf.albums, isEmpty);
    });
  });
}
