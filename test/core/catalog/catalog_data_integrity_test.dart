import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/catalog/catalog_service.dart';
import 'package:lauschi/core/providers/provider_type.dart';

// The catalog is curated by the Python tooling (tools/) and consumed
// as-is by the app: match() returns the curated episode number from
// series.yaml, never a fresh derivation (docs/catalog-episode-numbers.md).
// These tests pin the data invariants the app relies on, over the real
// shipped series.yaml.

const _providers = [ProviderType.spotify, ProviderType.appleMusic];

/// Every curated album with its owning series and provider.
Iterable<(CatalogSeries, ProviderType, CatalogAlbum)> _curatedAlbums(
  CatalogService catalog,
) sync* {
  for (final series in catalog.all) {
    for (final provider in _providers) {
      for (final album in series.albumsForProvider(provider)) {
        yield (series, provider, album);
      }
    }
  }
}

void main() {
  late CatalogService catalog;
  late Map<String, List<String>> shared;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    catalog = await CatalogService.load();
    shared = CatalogService.findSharedAlbumIds(catalog.all);
  });

  test('curated episode numbers agree with explicit Folge N in titles', () {
    // A curated number contradicting the number printed in the album
    // title means the kid's tile shows "Folge 7" for audio announcing
    // itself as Folge 12, sorted into the wrong position. The pipeline
    // curates the number; this cross-checks it against the one signal
    // parents and kids actually see.
    final folge = RegExp(r'\bFolge\s+(\d+)\b', caseSensitive: false);

    // Doppel-numbered title where the curation deliberately picks the
    // inner number: "Folge 10: Gute-Nacht-Geschichten Folge 19+20 ...".
    const knownAmbiguous = {'spotify:4J7VLI47aJNd2vQEdbfdDO'};

    final disagreements = <String>[];
    var compared = 0;
    for (final (series, provider, album) in _curatedAlbums(catalog)) {
      if (album.episode == null) continue;
      if (knownAmbiguous.contains('${provider.value}:${album.id}')) {
        continue;
      }
      final inTitle = folge.firstMatch(album.title);
      if (inTitle == null) continue;
      compared++;
      if (int.parse(inTitle.group(1)!) != album.episode) {
        disagreements.add(
          '${series.id}/${provider.value} ${album.id}: '
          'curated ${album.episode} but title says '
          '"${inTitle.group(0)}" — "${album.title}"',
        );
      }
    }

    expect(compared, greaterThan(5000), reason: 'catalog looks unloaded');
    expect(
      disagreements,
      isEmpty,
      reason:
          'Curated episode numbers contradict the album titles for '
          '${disagreements.length} of $compared albums:\n'
          '${disagreements.take(25).join('\n')}',
    );
  });

  test('every unshared curated album resolves to its owning series', () {
    // Guards the album index and match() plumbing: a curated album must
    // come back attributed to the series that curated it, carrying the
    // curated episode number. Ids curated under multiple series are
    // checked by the ratchet test below instead.
    final wrong = <String>[];
    var compared = 0;
    for (final (series, provider, album) in _curatedAlbums(catalog)) {
      if (shared.containsKey('${provider.value}:${album.id}')) continue;
      final match = catalog.match(
        album.title,
        albumId: album.id,
        albumProvider: provider,
      );
      compared++;
      if (match?.series.id != series.id ||
          match?.episodeNumber != album.episode) {
        wrong.add(
          '${series.id}/${provider.value} ${album.id}: resolved to '
          '${match?.series.id} ep ${match?.episodeNumber}, curated '
          'ep ${album.episode}',
        );
      }
    }

    expect(compared, greaterThan(10000), reason: 'catalog looks unloaded');
    expect(wrong, isEmpty, reason: wrong.take(25).join('\n'));
  });

  test('cross-series shared album ids do not grow', () {
    // Zero shared ids: every album now belongs to exactly one series.
    // The music collaborations (kati_breuer/stephen_janetzko, the
    // Flohtöne / Kalle Klang / Sing-Kinderlieder family, emmalu,
    // piano_papa, giraffenaffen) were each assigned to the album's
    // first-credited artist; the Hörspiel crossovers were excluded from
    // the wrong series. A new shared id means fresh curation bleed: the
    // same album curated into two series resolves to an arbitrary one,
    // and bulk-add silently skips it for the other. Keep this at zero;
    // never raise the bound without resolving the new entries by hand.
    expect(
      shared.length,
      isZero,
      reason:
          'New cross-series shared album ids appeared:\n'
          '${shared.entries.take(90).map((e) => '${e.key}: ${e.value.join(' + ')}').join('\n')}',
    );
  });

  test('series with duplicate episode numbers do not grow', () {
    // Within one series+provider, two albums carrying the same episode
    // number sort on top of each other in the kid's tile. 16 series still
    // have this, almost all because two distinct numbered lines share a
    // series entry (classic vs CGI, an original vs a "neue" run) and want
    // splitting, plus a few publisher number-reuses. pumuckl, jan_tenner,
    // and hanni_und_nanni were split into their two numbered lines. Lower
    // the bound as the rest are split or de-duplicated; never raise it
    // without checking the new collisions by hand.
    final offenders = <String>[];
    for (final series in catalog.all) {
      for (final provider in _providers) {
        final counts = <int, int>{};
        for (final album in series.albumsForProvider(provider)) {
          final ep = album.episode;
          if (ep != null) counts[ep] = (counts[ep] ?? 0) + 1;
        }
        final dupes = counts.entries.where((e) => e.value > 1).toList();
        if (dupes.isNotEmpty) {
          offenders.add(
            '${series.id}/${provider.value}: '
            '${dupes.map((e) => 'ep ${e.key} x${e.value}').join(', ')}',
          );
        }
      }
    }
    final seriesWithDupes = offenders.map((o) => o.split('/').first).toSet();

    expect(
      seriesWithDupes.length,
      lessThanOrEqualTo(16),
      reason:
          'Series with duplicate episode numbers grew:\n'
          '${offenders.join('\n')}',
    );
  });
}
