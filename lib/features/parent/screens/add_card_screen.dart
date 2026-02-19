import 'dart:async' show Timer, unawaited;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lauschi/core/database/card_repository.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/spotify/spotify_api.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/player/player_provider.dart';

const _tag = 'AddCard';

/// Search Spotify and add albums as cards to the collection.
///
/// Debounced search, results list, tap + to add.
/// Stays on screen after adding (add more workflow).
class AddCardScreen extends ConsumerStatefulWidget {
  const AddCardScreen({super.key});

  @override
  ConsumerState<AddCardScreen> createState() => _AddCardScreenState();
}

class _AddCardScreenState extends ConsumerState<AddCardScreen> {
  final _searchController = TextEditingController();
  Timer? _debounce;
  List<SpotifyAlbum> _results = [];
  bool _isSearching = false;
  final _addedUris = <String>{};

  @override
  void initState() {
    super.initState();
    unawaited(_loadExistingUris());
  }

  /// Pre-populate _addedUris from the database so existing cards show ✓.
  Future<void> _loadExistingUris() async {
    final cards = ref.read(cardRepositoryProvider);
    final all = await cards.getAll();
    if (mounted) {
      setState(() {
        _addedUris.addAll(all.map((c) => c.providerUri));
      });
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _onSearchChanged(String query) {
    _debounce?.cancel();
    if (query.trim().isEmpty) {
      setState(() {
        _results = [];
        _isSearching = false;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 400), () async {
      await _search(query.trim());
    });
  }

  Future<void> _search(String query) async {
    setState(() => _isSearching = true);

    try {
      final api = ref.read(spotifyApiProvider);
      final result = await api.searchAlbums(query);
      if (mounted) {
        setState(() {
          _results = result.albums;
          _isSearching = false;
        });
      }
    } on Exception catch (e) {
      Log.error(_tag, 'Search failed', exception: e);
      if (mounted) {
        setState(() => _isSearching = false);
      }
    }
  }

  Future<void> _addCard(SpotifyAlbum album) async {
    final cards = ref.read(cardRepositoryProvider);
    await cards.insertIfAbsent(
      title: album.name,
      providerUri: album.uri,
      cardType: 'album',
      coverUrl: album.imageUrl,
    );

    setState(() => _addedUris.add(album.uri));

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${album.name} hinzugefügt'),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.parentBackground,
      appBar: AppBar(
        backgroundColor: AppColors.parentBackground,
        title: const Text('Hörspiel hinzufügen'),
      ),
      body: Column(
        children: [
          // Search field
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.screenH,
              vertical: AppSpacing.sm,
            ),
            child: TextField(
              controller: _searchController,
              onChanged: _onSearchChanged,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'Suche auf Spotify...',
                prefixIcon: Icon(Icons.search_rounded),
              ),
            ),
          ),
          // Results
          Expanded(
            child:
                _isSearching
                    ? const Center(child: CircularProgressIndicator())
                    : _results.isEmpty
                    ? Center(
                      child: Text(
                        _searchController.text.isEmpty
                            ? 'Suche nach Hörspielen, Hörbüchern oder Alben.'
                            : 'Keine Ergebnisse.',
                        style: const TextStyle(
                          fontFamily: 'Nunito',
                          fontSize: 15,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    )
                    : ListView.builder(
                      itemCount: _results.length,
                      padding: const EdgeInsets.only(bottom: AppSpacing.xxl),
                      cacheExtent: 500,
                      itemBuilder: (context, index) {
                        final album = _results[index];
                        final isAdded = _addedUris.contains(album.uri);

                        return _SearchResultTile(
                          album: album,
                          isAdded: isAdded,
                          onAdd: () => _addCard(album),
                        );
                      },
                    ),
          ),
        ],
      ),
    );
  }
}

class _SearchResultTile extends StatelessWidget {
  const _SearchResultTile({
    required this.album,
    required this.isAdded,
    required this.onAdd,
  });

  final SpotifyAlbum album;
  final bool isAdded;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: ClipRRect(
        borderRadius: const BorderRadius.all(Radius.circular(6)),
        child: SizedBox(
          width: 48,
          height: 48,
          child:
              album.imageUrl != null
                  ? CachedNetworkImage(
                    imageUrl: album.imageUrl!,
                    fit: BoxFit.cover,
                    memCacheWidth: 96,
                  )
                  : const ColoredBox(
                    color: AppColors.surfaceDim,
                    child: Icon(Icons.music_note_rounded),
                  ),
        ),
      ),
      title: Text(
        album.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          fontFamily: 'Nunito',
          fontWeight: FontWeight.w600,
          fontSize: 15,
        ),
      ),
      subtitle: Text(
        '${album.artistNames} · ${album.totalTracks} Titel',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          fontFamily: 'Nunito',
          fontSize: 13,
          color: AppColors.textSecondary,
        ),
      ),
      trailing:
          isAdded
              ? const Icon(Icons.check_rounded, color: AppColors.success)
              : IconButton(
                onPressed: onAdd,
                icon: const Icon(Icons.add_rounded),
                color: AppColors.primary,
              ),
    );
  }
}
