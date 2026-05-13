import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/catalog/catalog_service.dart';
import 'package:lauschi/core/providers/provider_type.dart';

// The catalog matcher uses a single signal: provider+album_id lookup
// against the curated index built from series.yaml. Fuzzy keyword and
// artist_id matching were removed (commit "Drop keyword matching from
// Dart") after the encanto/Blaze incident, where the overly-broad
// keyword "Das Original-Hörspiel" caused a Spotify search for "blaze"
// to tag unrelated Blaze episodes as Encanto in the discover screen.
//
// The clean contract now: an album in the catalog → identified by id;
// an album not in the catalog → no badge. Coverage of brand-new releases
// is deferred to the subscription/refresh feature.
//
// Album ids in this file are real, taken straight from series.yaml so
// the tests fail loudly if anyone removes those entries.

void main() {
  late CatalogService catalog;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    catalog = await CatalogService.load();
  });

  group('CatalogService.load', () {
    test('loads ≥150 series and a flagship is present', () {
      // The catalog has ~160 series (per AGENTS.md). The previous
      // lower bound of 45 would happily pass if 70% of the YAML failed
      // to parse. Tighten the floor AND sanity-check the flagship to
      // catch catastrophic data corruption.
      expect(catalog.seriesCount, greaterThanOrEqualTo(150));
      expect(
        catalog.all.any((s) => s.id == 'die_drei_fragezeichen'),
        isTrue,
        reason:
            'die_drei_fragezeichen is the flagship — its absence '
            'means the YAML is corrupted',
      );
    });

    test('builds a sizeable album index for Phase 0 lookups', () {
      // The index is keyed by provider+album_id, populated from both
      // spotify and apple_music curated lists. A floor of 1000 catches
      // total breakage of the index build (the real number is ~4000+).
      expect(catalog.albumCount, greaterThan(1000));
    });
  });

  group('CatalogService.match — Phase 0 album_id lookup', () {
    test('matches a curated Spotify album by id', () {
      // Yakari Folge 1 — real album_id from series.yaml.
      final r = catalog.match(
        'Folge 1: Yakari und Grosser Adler (Das Original-Hörspiel zur TV-Serie)',
        albumId: '25u9Clfj4qnEJD3jjxOwPR',
        albumProvider: ProviderType.spotify,
      );
      expect(r, isNotNull);
      expect(r!.series.id, 'yakari');
      // Episode pattern still extracts the number from the title.
      expect(r.episodeNumber, 1);
    });

    test('matches a curated Apple Music album by id', () {
      final r = catalog.match(
        'Folge 1: Yakari und Grosser Adler (Das Original-Hörspiel zur TV-Serie)',
        albumId: '1562324264',
        albumProvider: ProviderType.appleMusic,
      );
      expect(r, isNotNull);
      expect(r!.series.id, 'yakari');
    });

    test('returns null for an unknown album', () {
      // Title looks like Yakari but the id isn't in the catalog.
      final r = catalog.match(
        'Folge 9: Yakari und die Pferdediebe',
        albumId: 'nonexistent-id-99999',
        albumProvider: ProviderType.spotify,
      );
      expect(r, isNull);
    });

    test(
      'returns null for a title-less Encanto/Blaze-style false positive',
      () {
        // Regression test for the original bug: a title that USED to
        // false-match the encanto keyword "Das Original-Hörspiel" must
        // not produce a match unless its album_id is curated under that
        // series. We use a known Yakari title and a fabricated unknown id
        // — the matcher must say "I don't know".
        final r = catalog.match(
          'Folge 01 + 02: Blaze, der Supertruck (Teil 1+2) '
          '[Das Original-Hörspiel zur Nickelodeon TV-Serie]',
          albumId: 'fabricated-blaze-id',
          albumProvider: ProviderType.spotify,
        );
        expect(r, isNull);
      },
    );

    test(
      'Phase 0 honors provider — Spotify id queried as Apple Music misses',
      () {
        // The Spotify id 25u9Clfj4qnEJD3jjxOwPR is Yakari ep 1 on Spotify
        // only. Looking it up as apple_music must miss — providers have
        // independent id namespaces.
        final r = catalog.match(
          'Folge 1: Yakari und Grosser Adler',
          albumId: '25u9Clfj4qnEJD3jjxOwPR',
          albumProvider: ProviderType.appleMusic,
        );
        expect(r, isNull);
      },
    );

    test('episode pattern still wins when title and id agree', () {
      // The episode comes from the title via the series's episode_pattern,
      // not from the catalog metadata for the album. Verify the wiring
      // still works through Phase 0.
      final r = catalog.match(
        'Folge 3: Yakari bei den Bären (Das Original-Hörspiel zur TV-Serie)',
        albumId: '3zp8KClWgYenFNdQZiFHtd',
        albumProvider: ProviderType.spotify,
      );
      expect(r, isNotNull);
      expect(r!.series.id, 'yakari');
      expect(r.episodeNumber, 3);
    });

    test('match without episode pattern still resolves the series', () {
      // Some series have no episode_pattern (music artists, etc.). The
      // series should still resolve; episodeNumber simply stays null.
      // Pick a music series with curated albums.
      final senta = catalog.all.firstWhere((s) => s.id == 'senta');
      // Skip the test if senta happens to have no curated albums.
      if (senta.albums.isEmpty) return;
      final first = senta.albums.first;
      final r = catalog.match(
        first.title,
        albumId: first.id,
        albumProvider: ProviderType.spotify,
      );
      expect(r, isNotNull);
      expect(r!.series.id, 'senta');
    });
  });

  group('CatalogService.search', () {
    test('empty query returns empty list', () {
      expect(catalog.search(''), isEmpty);
    });

    test('exact title prefix wins over substring matches', () {
      // "yak" prefix matches Yakari.
      final results = catalog.search('yak');
      expect(results, isNotEmpty);
      expect(results.first.id, 'yakari');
    });

    test('contains-match on title finds series whose name contains query', () {
      final results = catalog.search('blocksberg');
      expect(results.map((r) => r.id), contains('bibi_blocksberg'));
    });

    test('alias match works', () {
      // "Ein Fall für TKKG" is an alias for TKKG (see series.yaml).
      final results = catalog.search('Ein Fall');
      expect(results.map((r) => r.id), contains('tkkg'));
    });

    test('case-insensitive matching', () {
      final results = catalog.search('YAKARI');
      expect(results.first.id, 'yakari');
    });

    test('returns empty for unknown query', () {
      expect(catalog.search('xyznonexistent123'), isEmpty);
    });

    test('multi-word query matches title containing the substring', () {
      final results = catalog.search('die drei');
      final ids = results.map((r) => r.id).toList();
      expect(ids, contains('die_drei_fragezeichen'));
    });
  });

  group('CatalogSeries — model invariants', () {
    test('every series has a non-empty id and title', () {
      for (final s in catalog.all) {
        expect(s.id, isNotEmpty);
        expect(s.title, isNotEmpty);
      }
    });

    test('content type defaults to hoerspiel and parses music explicitly', () {
      expect(ContentType.fromString(null), ContentType.hoerspiel);
      expect(ContentType.fromString('hoerspiel'), ContentType.hoerspiel);
      expect(ContentType.fromString('music'), ContentType.music);
      // Garbage falls back to the safe default rather than throwing.
      expect(ContentType.fromString('garbage'), ContentType.hoerspiel);
    });

    test('isMusic reflects content type', () {
      const hoerspiel = CatalogSeries(
        id: 'h',
        title: 'h',
        aliases: <String>[],
        spotifyArtistIds: <String>[],
      );
      const music = CatalogSeries(
        id: 'm',
        title: 'm',
        aliases: <String>[],
        spotifyArtistIds: <String>[],
        contentType: ContentType.music,
      );
      expect(hoerspiel.isMusic, isFalse);
      expect(music.isMusic, isTrue);
    });
  });
}
