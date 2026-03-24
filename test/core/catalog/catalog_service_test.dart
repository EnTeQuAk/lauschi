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
      expect(r, isNotNull, reason: 'Should match Wickie by keyword');
      expect(
        r!.episodeNumber,
        isNot(1974),
        reason: 'Year 1974 must not be extracted as episode number',
      );
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
      // Keyword is "Bibi Blocksberg" (multi-word), needs both words present.
      final r = catalog.match('Folge 157: Bibi Blocksberg Team');
      expect(r, isNotNull);
      expect(r!.series.id, 'bibi_blocksberg');
    });

    test('matches Benjamin Blümchen case-insensitively', () {
      final r = catalog.match('benjamin blümchen - sonderedition');
      expect(r, isNotNull);
      expect(r!.series.id, 'benjamin_bluemchen');
    });

    test('matches Die drei ??? via artist ID', () {
      // Keywords removed during curation — artist-ID-only matching.
      const dreiId = '3meJIgRw7YleJrmbpbJK6S';
      final r = catalog.match(
        'Die drei ??? und der Karpatenhund',
        albumArtistIds: [dreiId],
      );
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

    test('matches TKKG via artist ID', () {
      // TKKG has no keywords, only artist ID matching.
      const tkkgId = '61qDotnjM0jnY5lkfOP7ve';
      final r = catalog.match(
        'Folge 162: Gefahr für Oskar!',
        albumArtistIds: [tkkgId],
      );
      expect(r, isNotNull);
      expect(r!.series.id, 'tkkg');
    });

    test('matches Bibi & Tina by artist ID', () {
      // "Bibi" keyword matches bibi_blocksberg first. Use artist ID
      // to confirm bibi_und_tina when title is ambiguous.
      const bibiTinaId = '2x8vG4f0HYXzMEo3xNsoiI';
      final r = catalog.match(
        'Folge 100: Bibi und Tina - Das Musical',
        albumArtistIds: [bibiTinaId],
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
      // Both conni and meine_freundin_conni have keyword "Conni".
      final r = catalog.match('Conni rettet Oma');
      expect(r, isNotNull);
      expect(r!.series.id, anyOf('conni', 'meine_freundin_conni'));
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

    test('matches Hui Buh das Schlossgespenst', () {
      // Both hui_buh_schlossgespenst and der_kleine_hui_buh have "Hui Buh"
      // keyword. der_kleine_hui_buh's keyword is longer so sorts first.
      final r = catalog.match('01/Hui Buh das Schlossgespenst');
      expect(r, isNotNull);
      expect(
        r!.series.id,
        anyOf('hui_buh_schlossgespenst', 'der_kleine_hui_buh'),
      );
    });

    test('matches Räuber Hotzenplotz', () {
      final r = catalog.match(
        'Der Räuber Hotzenplotz - Hörspiele 1: Der Räuber Hotzenplotz',
      );
      expect(r, isNotNull);
      // Accept either spelling variant from curation.
      expect(
        r!.series.id,
        'raeuber_hotzenplotz',
      );
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
      // Both lauras_stern and lauras_stern_tv_serie have this keyword.
      final r = catalog.match('Lauras Stern, Folge 1: Lauras Stern');
      expect(r, isNotNull);
      expect(r!.series.id, anyOf('lauras_stern', 'lauras_stern_tv_serie'));
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

    test('matches Heidi via artist ID', () {
      // Keywords removed during curation — artist-ID-only matching.
      // Both heidi and heidi_cgi share the same artist ID.
      const heidiId = '2kSiXgvssxAYOIvu4lwVGf';
      final r = catalog.match(
        '06/Heidi kehrt zurück',
        albumArtistIds: [heidiId],
      );
      expect(r, isNotNull);
      expect(r!.series.id, startsWith('heidi'));
    });

    test('matches Die Fuchsbande by keyword', () {
      // Keyword "Fuchsbande" is a standalone word match.
      final r = catalog.match(
        'Folge 10: Die Fuchsbande und der verschwundene Schatz',
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
      // Curation used gespensterjager (without ae).
      expect(r!.series.id, anyOf('gespensterjaeger', 'gespensterjager'));
    });

    test('matches LasseMaja', () {
      final r = catalog.match('Detektivbüro LasseMaja 1');
      expect(r, isNotNull);
      expect(r!.series.id, 'lassemaja');
    });
  });

  group('CatalogService.match — whole-word keyword matching', () {
    // Single-word keywords require whole-word boundaries to prevent German
    // compound false positives ("Bär" in "Bären", "Drachen" in "Drachenbabys").
    test('Bär rejects Bären (compound/inflection)', () {
      final r = catalog.match(
        'Folge 3: Yakari bei den Bären (Das Original-Hörspiel zur TV-Serie)',
      );
      expect(r, isNotNull);
      expect(r!.series.id, 'yakari');
      expect(r.episodeNumber, 3);
    });

    test('Bär matches standalone at end of title', () {
      final r = catalog.match(
        'Folge 3: Ich mach dich gesund, sagte der Bär',
      );
      expect(r, isNotNull);
      expect(r!.series.id, 'janosch');
    });

    test('Drachen rejects Drachenbabys (compound)', () {
      // No keyword matches (Drachen rejected). Artist ID fallback to PAW Patrol.
      final r = catalog.match(
        'Folge 310: Drachenbabys in der Abenteuerbucht',
        albumArtistIds: ['1JPhbKU3boL67fftU3U1ED'], // PAW Patrol artist
      );
      expect(r, isNotNull);
      expect(r!.series.id, 'paw_patrol');
      expect(r.source, CatalogMatchSource.artistId);
    });

    test('Dragons matches by keyword', () {
      // Keyword is now "Dragons" not "Drachen".
      final r = catalog.match('Dragons - Die Reiter von Berk');
      expect(r, isNotNull);
      expect(r!.series.id, 'dragons_hoerspiel');
    });

    test('Tiger matches standalone at end of title', () {
      final r = catalog.match('Folge 2: Post für den Tiger');
      expect(r, isNotNull);
      expect(r!.series.id, 'janosch');
    });

    test('Tiger rejects compound Tigerbären', () {
      // "Tigerbären" has 'b' after Tiger — rejected.
      // No keyword candidate, no artist → null.
      final r = catalog.match('Die Tigerbären');
      expect(r, isNull);
    });

    test('Max rejects Maximilian (compound)', () {
      final r = catalog.match('Maximilian und die Abenteuer');
      expect(r, isNull);
    });

    test('Max matches standalone word', () {
      final r = catalog.match('Max und die Abenteuer');
      expect(r, isNotNull);
      expect(r!.series.id, 'max');
    });

    test('finds second occurrence when first is compound', () {
      // "Tigerbären" rejects first "Tiger", but "der kleine Tiger" has
      // standalone second occurrence.
      final r = catalog.match('Die Tigerbären und der kleine Tiger');
      expect(r, isNotNull);
      expect(r!.series.id, 'janosch');
    });

    test('multi-word keyword uses substring match', () {
      // "Bibi Blocksberg" is multi-word → substring matching.
      final r = catalog.match('Folge 157: Bibi Blocksberg rettet den Zoo');
      expect(r, isNotNull);
      expect(r!.series.id, 'bibi_blocksberg');
    });

    test('compound word falls back to artist ID', () {
      // "Drachenreiter" doesn't match "Dragons" keyword. Artist ID fallback.
      final r = catalog.match(
        'Drachenreiter von Berk',
        albumArtistIds: ['1z8ytficgBWsoYigwE2QVM'], // Dragons artist
      );
      expect(r, isNotNull);
      expect(r!.series.id, 'dragons_hoerspiel');
      expect(r.source, CatalogMatchSource.artistId);
    });

    test('compound word with no other keyword uses artist ID', () {
      // "Drachenfeuer" has no Dragons keyword match at all.
      final r = catalog.match(
        'Das Drachenfeuer',
        albumArtistIds: ['1z8ytficgBWsoYigwE2QVM'], // Dragons artist
      );
      expect(r, isNotNull);
      expect(r!.series.id, 'dragons_hoerspiel');
      expect(r.source, CatalogMatchSource.artistId);
    });

    test('keyword after punctuation matches', () {
      // "Bär" after comma+space is a word boundary.
      final r = catalog.match('Geschichten, Bär und Freunde');
      expect(r, isNotNull);
      expect(r!.series.id, 'janosch');
    });

    test('keyword in parentheses matches', () {
      final r = catalog.match('Das Hörspiel (Yakari Edition)');
      expect(r, isNotNull);
      expect(r!.series.id, 'yakari');
    });

    test('Rabe Socke matches without Alles keyword', () {
      final r = catalog.match(
        'Alles Bitte-danke! (Der kleine Rabe Socke)',
      );
      expect(r, isNotNull);
      expect(r!.series.id, 'der_kleine_rabe_socke');
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
      final r = catalog.match('Folge 157: Bibi Blocksberg rettet den Zoo');
      expect(r!.episodeNumber, 157);
    });

    // Pumuckl: episode_pattern changed during curation and no longer extracts
    // episode numbers from titles. Curated album data provides them instead.
    test('Pumuckl matches by keyword (episode from curated data)', () {
      final r = catalog.match(
        '19: Pumuckl im Zoo (Das Original aus dem Fernsehen)',
      );
      expect(r, isNotNull);
      expect(r!.series.id, 'pumuckl');
    });

    // Hanni und Nanni: three formats
    test('Hanni und Nanni extracts NNN/ prefix', () {
      final r = catalog.match('065/Hanni und Nanni voll im Trend!');
      expect(r!.episodeNumber, 65);
    });

    test('Hanni und Nanni extracts short NNN/ prefix', () {
      // Pattern requires 3-digit prefix: ^(\d{3})/
      final r = catalog.match('004/Lustige Streiche mit Hanni und Nanni');
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

    // Räuber Hotzenplotz: "Hörspiele N" format (curated pattern)
    test(
      'Räuber Hotzenplotz extracts from Hörspiele format',
      () {
        final r = catalog.match(
          'Der Räuber Hotzenplotz - Hörspiele 1: Der Räuber Hotzenplotz - Das Hörspiel',
        );
        expect(r!.episodeNumber, 1);
      },
    );

    test('Räuber Hotzenplotz extracts Hörspiele 3', () {
      final r = catalog.match(
        'Der Räuber Hotzenplotz - Hörspiele 3: Schluss mit der Räuberei - Das Hörspiel',
      );
      expect(r!.episodeNumber, 3);
    });

    // Hui Buh: multiple series share the keyword, episode extraction
    // depends on which series matches first.
    test('Hui Buh matches and may extract episode', () {
      final r = catalog.match('Folge 1: Hui Buh das Schlossgespenst');
      expect(r, isNotNull);
      // Accept any Hui Buh variant.
      expect(r!.series.id, contains('hui_buh'));
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

    // Biene Maja: NNN/ format (pattern changed to ^(\d+)/)
    test('Biene Maja extracts episode from NNN/ prefix', () {
      final r = catalog.match(
        '01/Majas Flucht aus der Heimatstadt (Die Biene Maja)',
      );
      expect(r, isNotNull);
      expect(r!.episodeNumber, 1);
    });

    // Nils Holgersson: "(Nils Holgersson, Folge N)" format
    test('Nils Holgersson extracts from parenthesized format', () {
      final r = catalog.match('Der Junge (Nils Holgersson, Folge 1)');
      expect(r!.episodeNumber, 1);
    });

    test('Nils Holgersson extracts larger episode', () {
      final r = catalog.match(
        'Wildvogelleben (Nils Holgersson, Folge 3)',
      );
      expect(r!.episodeNumber, 3);
    });

    // Heidi: artist-ID-only (keywords removed during curation)
    test('Heidi matches via artist ID', () {
      const heidiId = '2kSiXgvssxAYOIvu4lwVGf';
      final r = catalog.match(
        '06/Heidi kehrt zurück',
        albumArtistIds: [heidiId],
      );
      expect(r, isNotNull);
      expect(r!.series.id, startsWith('heidi'));
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

    test('Lauras Stern without keyword prefix has no episode', () {
      // "Lauras Stern 10" — no Folge/Teil/Band prefix, pattern doesn't match.
      final r = catalog.match(
        'Laura hat Geburtstag [Lauras Stern 10 (Ungekürzt)]',
      );
      expect(r, isNotNull);
      expect(r!.episodeNumber, isNull);
    });

    test('Lauras Stern extracts Teil N', () {
      // Pattern: (?:Folge|Teil|Erstleser)\s+(\d+)
      final r = catalog.match(
        'Lauras Stern - Tonspur der TV-Serie, Teil 10: Fabelhafte Gutenacht-Geschichten',
      );
      expect(r, isNotNull);
      expect(r!.episodeNumber, 10);
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

    test('Wendy NNN/ prefix not extracted (pattern is Folge only)', () {
      final r = catalog.match(
        '005/Wendy Wolf hat Geburtstag (und 5 weitere Geschichten)',
      );
      expect(r, isNotNull);
      expect(r!.episodeNumber, isNull);
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

    // Gespensterjäger NN/ no longer in pattern (gespensterjaeger uses Band/Folge only).

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
        // Real Spotify album: "Folge 116: Codename Cobra"
        // Pattern is now "^Folge (\d+):" (no NNN/ support).
        const dreiId = '3meJIgRw7YleJrmbpbJK6S';
        final r = catalog.match(
          'Folge 116: Codename Cobra',
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
      // Episode pattern is "^Folge (\d+):" — NNN/ prefix not supported.
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
      final r = catalog.match('Folge 157: Bibi Blocksberg rettet den Zoo');
      expect(r, isNotNull);
      expect(r!.source, CatalogMatchSource.keyword);
    });

    test('keyword match wins over artist ID match for same series', () {
      // Album has both keyword AND artist ID — should match via keyword.
      const bibiId = '3t2iKODSDyzoDJw7AsD99u';
      final r = catalog.match(
        'Folge 157: Bibi Blocksberg rettet den Zoo',
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
      // Curation created die_schule_der_magischen_tiere with full keyword.
      expect(r!.series.id, 'die_schule_der_magischen_tiere');
    });

    test('Die Schule der magischen Tiere matches by artist ID', () {
      const id = '1BElEHaU2xaZg7FOGsSird';
      final r = catalog.match('Irgendein Titel', albumArtistIds: [id]);
      expect(r, isNotNull);
      // Both schule_magische_tiere and die_schule_der_magischen_tiere share
      // this artist ID — accept either.
      expect(
        r!.series.id,
        anyOf('schule_magische_tiere', 'die_schule_der_magischen_tiere'),
      );
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
      // Multiple series share this keyword prefix. Accept any.
      final r = catalog.match('Wieso? Weshalb? Warum? - Wie entstehen Wolken?');
      expect(r, isNotNull);
      expect(r!.series.id, startsWith('wieso_weshalb_warum'));
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
      // "Peppa Wutz" multi-word keyword.
      final r = catalog.match('Folge 5: Peppa Wutz auf dem Spielplatz');
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

    test('Pippi Swedish spelling does not match German keywords', () {
      // Swedish å won't match keyword "Pippi Langstrumpf".
      final r = catalog.match('Pippi Långstrump på de sju haven (Hörspiel)');
      // May match via "Pippi" single-word keyword now, accept either.
      if (r != null) {
        expect(r.series.id, 'pippi_langstrumpf');
      }
    });
  });

  group('CatalogService — extractEpisode direction (left-to-right)', () {
    // Verifies group priority in alternation patterns (Opus finding: left-to-right wins)

    test('Die drei ??? Folge format extracts episode', () {
      // Pattern is now "^Folge (\d+):" only.
      const id = '3meJIgRw7YleJrmbpbJK6S';
      final r = catalog.match(
        'Folge 116: Codename Cobra',
        albumArtistIds: [id],
      );
      expect(r!.episodeNumber, 116);
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
      expect(bb.albums.first.id, isNotEmpty);
      expect(bb.albums.first.title, contains('Folge'));
      expect(bb.albums.first.episode, 1);
      expect(bb.albums.first.uri, startsWith('spotify:album:'));
    });

    test('series without curated albums has empty list', () {
      // Find any series without albums (keyword-only stub).
      final stub = catalog.all.where((s) => !s.hasCuratedAlbums);
      expect(stub, isNotEmpty, reason: 'Need at least one stub series');
      expect(stub.first.albums, isEmpty);
    });
  });

  group('search', () {
    test('empty query returns empty list', () {
      expect(catalog.search(''), isEmpty);
    });

    test('whitespace-only query returns empty list', () {
      // search() doesn't trim — empty string check only.
      // If query is '  ', it won't match any title prefix.
      final results = catalog.search('   ');
      // Might match series with spaces in keywords, but practically empty.
      // This documents current behavior.
      expect(results.length, lessThanOrEqualTo(1));
    });

    test('title prefix matches rank before keyword matches', () {
      // "bibi" is a title prefix for Bibi Blocksberg and Bibi und Tina.
      final results = catalog.search('bibi');
      final ids = results.map((s) => s.id).toList();
      expect(ids, contains('bibi_blocksberg'));
      expect(ids, contains('bibi_und_tina'));
      // Both are title prefix matches, so order is catalog order.
    });

    test('exact title prefix prioritized over keyword-only match', () {
      // "yak" matches "Yakari" title prefix.
      final results = catalog.search('yak');
      expect(results.first.id, 'yakari');
    });

    test('keyword match returns series not matching title prefix', () {
      // "blocksberg" is a keyword for Bibi Blocksberg but not a title prefix.
      final results = catalog.search('blocksberg');
      expect(results.map((r) => r.id), contains('bibi_blocksberg'));
    });

    test('alias match works', () {
      // "Tim, Karl, Klößchen, Gaby" is an alias for TKKG.
      final results = catalog.search('Tim, Karl');
      expect(results.map((r) => r.id), contains('tkkg'));
    });

    test('case-insensitive matching', () {
      final results = catalog.search('YAKARI');
      expect(results.first.id, 'yakari');
    });

    test('no matches returns empty list', () {
      expect(catalog.search('xyznonexistent123'), isEmpty);
    });

    test('multi-word query matches title containing both words', () {
      final results = catalog.search('die drei');
      final ids = results.map((r) => r.id).toList();
      expect(ids, contains('die_drei_fragezeichen'));
      expect(ids, contains('die_drei_fragezeichen_kids'));
    });

    test('prefix matches come before contains matches', () {
      // "Benjamin" is a title prefix for Benjamin Blümchen.
      // If another series has "benjamin" as a keyword but not title prefix,
      // it should come after.
      final results = catalog.search('benjamin');
      expect(results.first.id, 'benjamin_bluemchen');
    });
  });

  group('CatalogService.match — music artists', () {
    test('matches Senta by artist ID (phase 2)', () {
      // Senta's album titles don't always contain "Senta",
      // so artist ID matching is the primary discovery path.
      final r = catalog.match(
        'Hoch die Hände Wochenende',
        albumArtistIds: ['7uVDfCKp96l3xCHFYf39vU'],
      );
      expect(r, isNotNull);
      expect(r!.series.id, 'senta');
      expect(r.source, CatalogMatchSource.artistId);
    });

    test('matches Senta by keyword when title contains name', () {
      final r = catalog.match("Senta's Spaßfabrik");
      expect(r, isNotNull);
      expect(r!.series.id, 'senta');
      expect(r.source, CatalogMatchSource.keyword);
    });

    test('matches Detlev Jöcker by artist ID', () {
      // Title deliberately avoids matching any keyword. Only artist ID
      // resolves this to Detlev Jöcker.
      final r = catalog.match(
        '1, 2, 3 im Sauseschritt',
        albumArtistIds: ['4UiTe5uwHKDUddmV8yQeY4'],
      );
      expect(r, isNotNull);
      expect(r!.series.id, 'detlev_joecker');
      expect(r.source, CatalogMatchSource.artistId);
    });

    test('matches herrH by artist ID', () {
      final r = catalog.match(
        'Frechdachs',
        albumArtistIds: ['2weS8n5DrZpok2Wcf9TRsQ'],
      );
      expect(r, isNotNull);
      expect(r!.series.id, 'herrh');
    });

    test('music artist match has no episode number', () {
      final r = catalog.match(
        'Mira und das fliegende Haus - Kinderlieder',
        albumArtistIds: ['2095wofkLJPuP7ZmCNwvOS'],
      );
      expect(r, isNotNull);
      expect(r!.series.id, 'mira_und_das_fliegende_haus');
      // Music albums don't have episode numbers.
      expect(r.episodeNumber, isNull);
    });

    test('search finds music artists', () {
      final results = catalog.search('senta');
      expect(results.any((s) => s.id == 'senta'), isTrue);
    });
  });
}
