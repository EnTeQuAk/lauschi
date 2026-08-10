import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/catalog/catalog_source.dart';
import 'package:lauschi/core/providers/provider_type.dart';

CatalogAlbumResult _album({
  String? artworkUrl,
  List<({String? url, int? width})> renditions = const [],
}) => CatalogAlbumResult(
  id: 'a',
  name: 'A',
  artistName: 'X',
  artistIds: const [],
  provider: ProviderType.spotify,
  artworkUrl: artworkUrl,
  artworkRenditions: renditions,
);

void main() {
  group('CatalogAlbumResult.artworkUrlForSize', () {
    test('picks the smallest rendition covering the requested size', () {
      final album = _album(
        artworkUrl: 'https://img/640',
        renditions: [
          (url: 'https://img/640', width: 640),
          (url: 'https://img/300', width: 300),
          (url: 'https://img/64', width: 64),
        ],
      );
      expect(album.artworkUrlForSize(300), 'https://img/300');
      expect(album.artworkUrlForSize(200), 'https://img/300');
      expect(album.artworkUrlForSize(64), 'https://img/64');
      expect(album.artworkUrlForSize(400), 'https://img/640');
    });

    test('falls back to artworkUrl when nothing is big enough', () {
      final album = _album(
        artworkUrl: 'https://img/640',
        renditions: [(url: 'https://img/640', width: 640)],
      );
      expect(album.artworkUrlForSize(2000), 'https://img/640');
    });

    test('fills Apple Music size templates', () {
      final album = _album(artworkUrl: 'https://img/{w}x{h}bb.jpg');
      expect(album.artworkUrlForSize(300), 'https://img/300x300bb.jpg');
    });

    test('returns null without any artwork', () {
      expect(_album().artworkUrlForSize(300), isNull);
    });
  });
}
