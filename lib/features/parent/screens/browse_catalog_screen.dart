import 'dart:async' show unawaited;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lauschi/core/catalog/catalog_service.dart';
import 'package:lauschi/core/database/card_repository.dart';
import 'package:lauschi/core/database/group_repository.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/router/app_router.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/player/player_provider.dart';

const _tag = 'BrowseCatalog';

// ── Browse catalog grid ─────────────────────────────────────────────────────

/// Curated series grid. Shows all series with albums in the catalog.
/// Parents tap a series to see episodes and add cards.
class BrowseCatalogScreen extends ConsumerWidget {
  const BrowseCatalogScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final catalogAsync = ref.watch(catalogServiceProvider);

    return Scaffold(
      backgroundColor: AppColors.parentBackground,
      appBar: AppBar(
        backgroundColor: AppColors.parentBackground,
        title: const Text('Katalog'),
        actions: [
          IconButton(
            icon: const Icon(Icons.search_rounded),
            tooltip: 'Bei Spotify suchen',
            onPressed: () => context.push(AppRoutes.parentAddCard),
          ),
        ],
      ),
      body: catalogAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Fehler: $e')),
        data: (catalog) {
          final series =
              catalog.all.where((s) => s.hasCuratedAlbums).toList()
                ..sort((a, b) => a.title.compareTo(b.title));

          if (series.isEmpty) {
            return const Center(
              child: Text(
                'Noch keine Serien im Katalog.',
                style: TextStyle(color: AppColors.textSecondary),
              ),
            );
          }

          return GridView.builder(
            padding: const EdgeInsets.all(AppSpacing.md),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              mainAxisSpacing: AppSpacing.md,
              crossAxisSpacing: AppSpacing.md,
              childAspectRatio: 0.75,
            ),
            itemCount: series.length,
            itemBuilder: (context, index) =>
                _SeriesCard(series: series[index]),
          );
        },
      ),
    );
  }
}

class _SeriesCard extends ConsumerWidget {
  const _SeriesCard({required this.series});

  final CatalogSeries series;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final coverMap = ref.watch(_seriesCoverMapProvider).value ?? {};
    final firstAlbumId =
        series.albums.isNotEmpty ? series.albums.first.spotifyId : null;
    final coverUrl =
        firstAlbumId != null ? coverMap[firstAlbumId] : null;

    return GestureDetector(
      onTap: () => context.push(
        AppRoutes.parentCatalogSeries(series.id),
      ),
      child: Column(
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: const BorderRadius.all(AppRadius.card),
              child: coverUrl != null
                  ? CachedNetworkImage(
                      imageUrl: coverUrl,
                      fit: BoxFit.cover,
                      width: double.infinity,
                      height: double.infinity,
                      placeholder: (_, _) =>
                          _Placeholder(title: series.title),
                      errorWidget: (_, _, _) =>
                          _Placeholder(title: series.title),
                    )
                  : _Placeholder(title: series.title),
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            series.title,
            style: const TextStyle(
              fontFamily: 'Nunito',
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
          Text(
            '${series.albums.length} Folgen',
            style: const TextStyle(
              fontFamily: 'Nunito',
              fontSize: 10,
              color: AppColors.textSecondary,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

// ── Series detail ───────────────────────────────────────────────────────────

/// Shows episodes for a catalog series. Parents can select and add them as
/// cards in one batch.
class CatalogSeriesDetailScreen extends ConsumerStatefulWidget {
  const CatalogSeriesDetailScreen({required this.seriesId, super.key});

  final String seriesId;

  @override
  ConsumerState<CatalogSeriesDetailScreen> createState() =>
      _CatalogSeriesDetailScreenState();
}

class _CatalogSeriesDetailScreenState
    extends ConsumerState<CatalogSeriesDetailScreen> {
  final _selected = <String>{};
  final _existingUris = <String>{};
  bool _selectAll = true;
  bool _isAdding = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadExisting());
  }

  Future<void> _loadExisting() async {
    final cards = await ref.read(cardRepositoryProvider).getAll();
    if (mounted) {
      setState(() {
        _existingUris.addAll(cards.map((c) => c.providerUri));
      });
    }
  }

  CatalogSeries? _findSeries(CatalogService catalog) {
    final matches = catalog.all.where((s) => s.id == widget.seriesId);
    return matches.isEmpty ? null : matches.first;
  }

  void _toggleSelectAll(CatalogSeries series) {
    setState(() {
      _selectAll = !_selectAll;
      if (_selectAll) {
        _selected.addAll(
          series.albums
              .where(
                (a) =>
                    !_existingUris.contains('spotify:album:${a.spotifyId}'),
              )
              .map((a) => a.spotifyId),
        );
      } else {
        _selected.clear();
      }
    });
  }

  Future<void> _addSelected(CatalogSeries series) async {
    if (_selected.isEmpty) return;

    setState(() => _isAdding = true);

    final api = ref.read(spotifyApiProvider);
    if (!api.hasToken) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Spotify nicht verbunden')),
        );
        setState(() => _isAdding = false);
      }
      return;
    }

    try {
      // Fetch album details for selected IDs (batched by Spotify API)
      final albumIds = _selected.toList();
      final albums = await api.getAlbums(albumIds);

      // Find or create group for the series
      final groupRepo = ref.read(groupRepositoryProvider);
      final cardRepo = ref.read(cardRepositoryProvider);
      final groups = await groupRepo.getAll();
      var groupId = groups
          .where(
            (g) => g.title.toLowerCase() == series.title.toLowerCase(),
          )
          .firstOrNull
          ?.id;

      if (groupId == null) {
        final firstAlbum = albums.isNotEmpty ? albums.first : null;
        groupId = await groupRepo.insert(
          title: series.title,
          coverUrl: firstAlbum?.imageUrl,
        );
        Log.info(_tag, 'Created group: ${series.title}');
      }

      var added = 0;
      for (final album in albums) {
        final uri = album.uri;
        if (_existingUris.contains(uri)) continue;

        // Extract episode number from catalog data
        final catalogAlbum = series.albums
            .where((a) => a.spotifyId == album.id)
            .firstOrNull;

        final cardId = await cardRepo.insert(
          title: album.name,
          providerUri: uri,
          coverUrl: album.imageUrl,
          cardType: 'album',
          spotifyArtistIds: album.artistIds,
          totalTracks: album.totalTracks,
        );
        await cardRepo.assignToGroup(
          cardId: cardId,
          groupId: groupId,
          episodeNumber: catalogAlbum?.episode,
        );

        _existingUris.add(uri);
        added++;
      }

      Log.info(
        _tag,
        'Added $added cards to ${series.title}',
        data: {'seriesId': series.id, 'count': added},
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('$added Folgen zu ${series.title} hinzugefügt'),
          ),
        );
        setState(() {
          _selected.clear();
          _isAdding = false;
        });
      }
    } on Exception catch (e) {
      Log.error(_tag, 'Failed to add cards', exception: e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Fehler: $e')),
        );
        setState(() => _isAdding = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final catalogAsync = ref.watch(catalogServiceProvider);

    return catalogAsync.when(
      loading: () => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Scaffold(
        body: Center(child: Text('Fehler: $e')),
      ),
      data: (catalog) {
        final series = _findSeries(catalog);
        if (series == null) {
          return Scaffold(
            appBar: AppBar(title: const Text('Nicht gefunden')),
            body: const Center(child: Text('Serie nicht gefunden.')),
          );
        }

        final albums = series.albums.toList()
          ..sort(
            (a, b) =>
                (a.episode ?? 999999).compareTo(b.episode ?? 999999),
          );

        // Pre-select all non-existing albums on first build
        if (_selected.isEmpty && _selectAll) {
          for (final album in albums) {
            if (!_existingUris.contains(
              'spotify:album:${album.spotifyId}',
            )) {
              _selected.add(album.spotifyId);
            }
          }
        }

        final selectableCount = albums
            .where(
              (a) => !_existingUris.contains(
                'spotify:album:${a.spotifyId}',
              ),
            )
            .length;

        return Scaffold(
          backgroundColor: AppColors.parentBackground,
          appBar: AppBar(
            backgroundColor: AppColors.parentBackground,
            title: Text(series.title),
            actions: [
              if (selectableCount > 0)
                TextButton(
                  onPressed: () => _toggleSelectAll(series),
                  child: Text(
                    _selectAll ? 'Keine' : 'Alle',
                    style: const TextStyle(fontFamily: 'Nunito'),
                  ),
                ),
            ],
          ),
          body: ListView.builder(
            itemCount: albums.length,
            itemBuilder: (context, index) {
              final album = albums[index];
              final uri = 'spotify:album:${album.spotifyId}';
              final alreadyAdded = _existingUris.contains(uri);
              final isSelected = _selected.contains(album.spotifyId);

              return _AlbumTile(
                album: album,
                alreadyAdded: alreadyAdded,
                isSelected: isSelected,
                onChanged: () {
                  setState(() {
                    if (isSelected) {
                      _selected.remove(album.spotifyId);
                    } else {
                      _selected.add(album.spotifyId);
                    }
                  });
                },
              );
            },
          ),
          bottomNavigationBar: _selected.isNotEmpty
              ? SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpacing.md),
                    child: FilledButton.icon(
                      onPressed:
                          _isAdding ? null : () => _addSelected(series),
                      icon: _isAdding
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                              ),
                            )
                          : const Icon(Icons.add_rounded),
                      label: Text(
                        '${_selected.length} Folgen hinzufügen',
                        style: const TextStyle(fontFamily: 'Nunito'),
                      ),
                    ),
                  ),
                )
              : null,
        );
      },
    );
  }
}

// ── Album tile ──────────────────────────────────────────────────────────────

class _AlbumTile extends StatelessWidget {
  const _AlbumTile({
    required this.album,
    required this.alreadyAdded,
    required this.isSelected,
    required this.onChanged,
  });

  final CatalogAlbum album;
  final bool alreadyAdded;
  final bool isSelected;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: alreadyAdded
          ? const Icon(Icons.check_circle, color: AppColors.success)
          : Checkbox(value: isSelected, onChanged: (_) => onChanged()),
      title: Text(
        album.title,
        style: TextStyle(
          fontFamily: 'Nunito',
          fontSize: 14,
          color: alreadyAdded
              ? AppColors.textSecondary
              : AppColors.textPrimary,
        ),
      ),
      subtitle: album.episode != null
          ? Text(
              'Folge ${album.episode}',
              style: const TextStyle(
                fontFamily: 'Nunito',
                fontSize: 12,
                color: AppColors.textSecondary,
              ),
            )
          : null,
      enabled: !alreadyAdded,
      onTap: alreadyAdded ? null : onChanged,
    );
  }
}

// ── Shared ───────────────────────────────────────────────────────────────────

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) {
    final hue = (title.hashCode % 360).abs().toDouble();
    return Container(
      width: double.infinity,
      height: double.infinity,
      decoration: BoxDecoration(
        color: HSLColor.fromAHSL(1, hue, 0.3, 0.25).toColor(),
        borderRadius: const BorderRadius.all(AppRadius.card),
      ),
      child: Center(
        child: Icon(
          Icons.headphones_rounded,
          color: HSLColor.fromAHSL(1, hue, 0.4, 0.5).toColor(),
          size: 32,
        ),
      ),
    );
  }
}

/// Batch-fetches cover images for all curated series. Returns a map of
/// album ID → image URL. Spotify allows 20 IDs per request, so this
/// batches efficiently instead of N individual calls.
final _seriesCoverMapProvider =
    FutureProvider.autoDispose<Map<String, String>>((ref) async {
  final api = ref.watch(spotifyApiProvider);
  if (!api.hasToken) return {};

  final catalogAsync = ref.watch(catalogServiceProvider);
  final catalog = catalogAsync.value;
  if (catalog == null) return {};

  // Collect first album ID from each curated series
  final albumIds = <String>[];
  for (final series in catalog.all) {
    if (series.hasCuratedAlbums) {
      albumIds.add(series.albums.first.spotifyId);
    }
  }

  if (albumIds.isEmpty) return {};

  // Fetch in batches of 20 (Spotify API limit)
  final coverMap = <String, String>{};
  for (var i = 0; i < albumIds.length; i += 20) {
    final batch = albumIds.sublist(
      i,
      i + 20 > albumIds.length ? albumIds.length : i + 20,
    );
    try {
      final albums = await api.getAlbums(batch);
      for (final album in albums) {
        final url = album.imageUrl;
        if (url != null) {
          coverMap[album.id] = url;
        }
      }
    } on Exception {
      // Skip failed batch, show placeholders
    }
  }

  return coverMap;
});
