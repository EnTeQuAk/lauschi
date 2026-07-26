import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/catalog/catalog_service.dart';
import 'package:lauschi/core/providers/provider_type.dart';

// The catalog is curated by the Python tooling (tools/) and consumed by
// this app, so the two must agree on what an album's episode number is.
// They derive it differently:
//
//   Python  matcher.extract_episode  tries each pattern in a list in
//           order, reads capture group 1 only, case-sensitive, and
//           repairs double-escaped shortcuts (\\d -> \d).
//   Dart    _extractEpisode joins a pattern list into one alternation
//           (?:p1)|(?:p2), walks every capture group left-to-right, and
//           matches case-insensitively.
//
// Those are not the same algorithm. This test pins that they nonetheless
// agree on the real catalog: for every curated album, the number the app
// derives from the stored title must equal the number Python wrote into
// series.yaml. A disagreement means a kid sees a different episode
// number than we curated.
void main() {
  late CatalogService catalog;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    catalog = await CatalogService.load();
  });

  test('app-derived episode numbers agree with the curated ones', () {
    final disagreements = <String>[];
    var compared = 0;

    for (final series in catalog.all) {
      for (final provider in [ProviderType.spotify, ProviderType.appleMusic]) {
        for (final album in series.albumsForProvider(provider)) {
          if (album.episode == null) continue; // nothing curated to compare
          final match = catalog.match(
            album.title,
            albumId: album.id,
            albumProvider: provider,
          );
          compared++;
          if (match?.episodeNumber != album.episode) {
            disagreements.add(
              '${series.id}/${provider.value} ${album.id}: '
              'curated ${album.episode}, app derived '
              '${match?.episodeNumber} from "${album.title}"',
            );
          }
        }
      }
    }

    expect(compared, greaterThan(5000), reason: 'catalog looks unloaded');
    expect(
      disagreements,
      isEmpty,
      reason:
          'The app derives different episode numbers than the curation for '
          '${disagreements.length} of $compared albums:\n'
          '${disagreements.take(25).join('\n')}',
    );
  });
}
