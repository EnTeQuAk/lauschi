import 'dart:async' show unawaited;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lauschi/core/catalog/catalog_service.dart';
import 'package:lauschi/core/database/content_importer.dart';
import 'package:lauschi/core/database/tile_item_repository.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/providers/provider_type.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/parent/widgets/catalog/catalog_helpers.dart';
import 'package:lauschi/features/parent/widgets/import_progress_dialog.dart';

const _tag = 'CatalogSeriesDetail';

/// Shows episodes for a catalog series. Parents can select and add them as
/// cards in one batch.
class CatalogSeriesDetailScreen extends ConsumerStatefulWidget {
  const CatalogSeriesDetailScreen({
    required this.seriesId,
    required this.provider,
    super.key,
    this.autoAssignTileId,
  });

  final String seriesId;
  final ProviderType provider;
  final String? autoAssignTileId;

  @override
  ConsumerState<CatalogSeriesDetailScreen> createState() =>
      _CatalogSeriesDetailScreenState();
}

class _CatalogSeriesDetailScreenState
    extends ConsumerState<CatalogSeriesDetailScreen> {
  final _selected = <String>{};
  bool _selectAll = true;
  bool _isAdding = false;

  CatalogSeries? _findSeries(CatalogService catalog) {
    final matches = catalog.all.where((s) => s.id == widget.seriesId);
    return matches.isEmpty ? null : matches.first;
  }

  void _toggleSelectAll(CatalogSeries series) {
    setState(() {
      _selectAll = !_selectAll;
      if (_selectAll) {
        final uris = ref.read(existingItemUrisProvider);
        final albums = series.albumsForProvider(widget.provider);
        _selected.addAll(
          albums.where((a) => !uris.contains(a.uri)).map((a) => a.id),
        );
      } else {
        _selected.clear();
      }
    });
  }

  Future<void> _addSelected(CatalogSeries series) async {
    if (_selected.isEmpty) return;
    if (ref.read(contentImporterProvider).isImporting) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Import läuft bereits.')),
      );
      return;
    }

    setState(() => _isAdding = true);

    final source = resolveSourceWidget(ref, widget.provider.value);
    if (source == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${widget.provider.displayName} nicht verbunden',
            ),
          ),
        );
        setState(() => _isAdding = false);
      }
      return;
    }

    final progressNotifier = ValueNotifier<(int, int)>((0, _selected.length));
    final statusNotifier = ValueNotifier<String>(
      'Lade ${series.title}…',
    );

    if (mounted) {
      unawaited(
        showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder:
              (_) => ImportProgressDialog(
                progress: progressNotifier,
                status: statusNotifier,
              ),
        ),
      );
    }

    final importer = ref.read(contentImporterProvider.notifier);

    try {
      final albumIds = _selected.toList();
      final providerAlbums = series.albumsForProvider(widget.provider);

      final covers = await source.getAlbumCovers(albumIds);
      if (!mounted) return;

      statusNotifier.value = 'Speichere ${series.title}…';

      final cards = <PendingCard>[];
      for (final albumId in albumIds) {
        final catalogAlbum =
            providerAlbums.where((a) => a.id == albumId).firstOrNull;
        if (catalogAlbum == null) continue;

        cards.add(
          PendingCard(
            title: catalogAlbum.title,
            providerUri: catalogAlbum.uri,
            cardType: 'album',
            provider: widget.provider,
            coverUrl: covers[albumId],
            episodeNumber: catalogAlbum.episode,
            spotifyArtistIds:
                widget.provider == ProviderType.spotify
                    ? series.spotifyArtistIds
                    : const [],
          ),
        );
      }

      final firstCoverUrl = covers.values.firstOrNull;
      final result = await importer.importToGroup(
        groupTitle: series.title,
        groupCoverUrl: firstCoverUrl,
        cards: cards,
        tileId: widget.autoAssignTileId,
        onProgress: (done, total) {
          progressNotifier.value = (done, total);
        },
      );

      Log.info(
        _tag,
        'Added ${result.added} cards to ${series.title}',
        data: {'seriesId': series.id, 'count': result.added},
      );

      if (mounted) {
        Navigator.of(context).pop(); // dismiss dialog
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${result.added} ${series.isMusic ? 'Alben' : 'Folgen'} zu ${series.title} hinzugefügt',
            ),
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
        Navigator.of(context).pop(); // dismiss dialog
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Fehler: $e')),
        );
        setState(() => _isAdding = false);
      }
    } finally {
      progressNotifier.dispose();
      statusNotifier.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final existingUris = ref.watch(existingItemUrisProvider);
    final cardsLoaded = ref.watch(allTileItemsProvider).hasValue;
    final catalogAsync = ref.watch(catalogServiceProvider);

    return catalogAsync.when(
      loading:
          () => const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          ),
      error:
          (e, _) => Scaffold(
            body: Center(child: Text('Fehler: $e')),
          ),
      data: (catalog) {
        final series = _findSeries(catalog);
        if (series == null) {
          return Scaffold(
            appBar: AppBar(title: const Text('Nicht gefunden')),
            body: const Center(child: Text('Kachel nicht gefunden.')),
          );
        }

        final albums =
            series.albumsForProvider(widget.provider).toList()..sort(
              (a, b) => (a.episode ?? 999999).compareTo(b.episode ?? 999999),
            );

        final coverKey =
            '${widget.provider.value}:${albums.map((a) => a.id).join(',')}';
        final coverMap = ref.watch(albumCoversProvider(coverKey)).value ?? {};

        if (_selected.isEmpty && _selectAll && cardsLoaded) {
          for (final album in albums) {
            if (!existingUris.contains(album.uri)) {
              _selected.add(album.id);
            }
          }
        }

        final selectableCount =
            albums.where((a) => !existingUris.contains(a.uri)).length;

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
              final alreadyAdded = existingUris.contains(album.uri);
              final isSelected = _selected.contains(album.id);

              return _AlbumTile(
                album: album,
                coverUrl: coverMap[album.id],
                alreadyAdded: alreadyAdded,
                isSelected: isSelected,
                onChanged: () {
                  setState(() {
                    if (isSelected) {
                      _selected.remove(album.id);
                    } else {
                      _selected.add(album.id);
                    }
                  });
                },
              );
            },
          ),
          bottomNavigationBar:
              _selected.isNotEmpty
                  ? SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpacing.md),
                      child: FilledButton.icon(
                        onPressed:
                            _isAdding ? null : () => _addSelected(series),
                        icon:
                            _isAdding
                                ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                                : const Icon(Icons.add_rounded),
                        label: Text(
                          '${_selected.length} ${series.isMusic ? 'Alben' : 'Folgen'} hinzufügen',
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

// ── Album tile (series detail) ──────────────────────────────────────────────

/// Checkbox tile for a single album within the series detail screen.
/// Kept in this file since it's tightly coupled to the series selection state.
class _AlbumTile extends StatelessWidget {
  const _AlbumTile({
    required this.album,
    required this.alreadyAdded,
    required this.isSelected,
    required this.onChanged,
    this.coverUrl,
  });

  final CatalogAlbum album;
  final bool alreadyAdded;
  final bool isSelected;
  final VoidCallback onChanged;
  final String? coverUrl;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 32,
            height: 32,
            child: Center(
              child:
                  alreadyAdded
                      ? const Icon(Icons.check_circle, color: AppColors.success)
                      : Checkbox(
                        value: isSelected,
                        onChanged: (_) => onChanged(),
                      ),
            ),
          ),
          const SizedBox(width: 8),
          ClipRRect(
            borderRadius: const BorderRadius.all(Radius.circular(4)),
            child:
                coverUrl != null
                    ? CachedNetworkImage(
                      imageUrl: coverUrl!,
                      width: 44,
                      height: 44,
                      fit: BoxFit.cover,
                    )
                    : const SizedBox(
                      width: 44,
                      height: 44,
                      child: ColoredBox(
                        color: AppColors.surfaceDim,
                        child: Icon(
                          Icons.album_rounded,
                          size: 20,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ),
          ),
        ],
      ),
      title: Text(
        album.title,
        style: TextStyle(
          fontFamily: 'Nunito',
          fontSize: 14,
          color: alreadyAdded ? AppColors.textSecondary : AppColors.textPrimary,
        ),
      ),
      subtitle:
          album.episode != null
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
