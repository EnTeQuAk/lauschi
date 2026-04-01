import 'package:lauschi/core/ard/ard_api.dart';
import 'package:lauschi/core/ard/ard_helpers.dart';
import 'package:lauschi/core/ard/ard_image.dart';
import 'package:lauschi/core/ard/ard_models.dart';
import 'package:lauschi/core/database/tile_item_repository.dart';
import 'package:lauschi/core/database/tile_repository.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/providers/provider_type.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'content_importer.g.dart';

const _tag = 'ContentImporter';

/// A pending card to be imported. Provider-agnostic.
class PendingCard {
  const PendingCard({
    required this.title,
    required this.providerUri,
    required this.cardType,
    required this.provider,
    this.coverUrl,
    this.episodeNumber,
    this.spotifyArtistIds,
    this.totalTracks = 0,
    this.audioUrl,
    this.durationMs,
    this.availableUntil,
  });

  final String title;
  final String providerUri;
  final String cardType;
  final ProviderType provider;
  final String? coverUrl;
  final int? episodeNumber;

  // Spotify fields
  final List<String>? spotifyArtistIds;
  final int totalTracks;

  // ARD fields
  final String? audioUrl;
  final int? durationMs;
  final DateTime? availableUntil;
}

/// Result of a content import operation.
class ImportResult {
  const ImportResult({required this.added, required this.groupTitle});

  final int added;
  final String groupTitle;
}

// ── Import state ────────────────────────────────────────────────────────────

sealed class ImportState {
  const ImportState();
  bool get isImporting => this is ImportRunning;
}

final class ImportIdle extends ImportState {
  const ImportIdle();
}

final class ImportRunning extends ImportState {
  const ImportRunning({
    required this.showTitle,
    required this.status,
    this.done = 0,
    this.total = 0,
  });

  final String showTitle;
  final String status;
  final int done;
  final int total;
}

final class ImportDone extends ImportState {
  const ImportDone({required this.added, required this.showTitle});

  final int added;
  final String showTitle;
}

final class ImportFailed extends ImportState {
  const ImportFailed({required this.message});

  final String message;
}

// ── Content importer ────────────────────────────────────────────────────────

/// Shared content import logic for all providers.
///
/// Handles find-or-create group, insert cards (skipping existing),
/// state tracking, and ARD page loading. Lives outside the widget tree
/// so imports survive navigation.
@Riverpod(keepAlive: true)
class ContentImporter extends _$ContentImporter {
  int _generation = 0;

  @override
  ImportState build() => const ImportIdle();

  TileItemRepository get _cardRepo => ref.read(tileItemRepositoryProvider);
  TileRepository get _groupRepo => ref.read(tileRepositoryProvider);

  /// Import all episodes from an ARD show.
  ///
  /// Loads remaining pages from the API if needed, then imports all
  /// playable episodes. Owns the full state lifecycle: idle -> running
  /// -> done/failed.
  Future<void> importArdShow({
    required String showId,
    required String showTitle,
    required String? showImageUrl,
    required List<ArdItem> loadedItems,
    required bool hasMorePages,
    String? endCursor,
    String? tileId,
  }) async {
    if (state.isImporting) return;

    final gen = ++_generation;
    state = ImportRunning(showTitle: showTitle, status: 'Lade $showTitle…');

    var added = 0;
    try {
      var allItems = loadedItems;
      if (hasMorePages && endCursor != null) {
        final api = ref.read(ardApiProvider);
        allItems = await _loadRemainingPages(
          api,
          showId,
          loadedItems,
          endCursor,
        );
      }

      final playable = allItems.where((i) => i.bestAudioUrl != null).toList();
      final cards = playable.map(ardPendingCard).toList();

      added = await _insertCards(
        groupTitle: showTitle,
        groupCoverUrl: ardImageUrl(showImageUrl),
        cards: cards,
        tileId: tileId,
        onProgress: (done, total) {
          state = ImportRunning(
            showTitle: showTitle,
            status: 'Speichere $showTitle…',
            done: done,
            total: total,
          );
        },
      );

      state = ImportDone(added: added, showTitle: showTitle);
    } on Exception catch (e) {
      Log.error(_tag, 'ARD show import failed', exception: e);
      state = ImportFailed(
        message:
            added > 0 ? '$added bereits hinzugefügt, dann Fehler: $e' : '$e',
      );
    }
    _autoReset(gen);
  }

  /// Import a batch of pre-built cards into a group.
  ///
  /// For Spotify, Apple Music, featured section, and single-episode adds.
  /// Owns the full state lifecycle when called directly.
  Future<ImportResult> importToGroup({
    required String groupTitle,
    required List<PendingCard> cards,
    String? groupCoverUrl,
    String? tileId,
    void Function(int done, int total)? onProgress,
  }) async {
    if (state.isImporting) {
      throw StateError('Import already in progress');
    }

    final gen = ++_generation;
    state = ImportRunning(showTitle: groupTitle, status: 'Speichere…');

    var added = 0;
    try {
      added = await _insertCards(
        groupTitle: groupTitle,
        groupCoverUrl: groupCoverUrl,
        cards: cards,
        tileId: tileId,
        onProgress: onProgress,
      );

      state = ImportDone(added: added, showTitle: groupTitle);
      _autoReset(gen);
      return ImportResult(added: added, groupTitle: groupTitle);
    } on Exception catch (e) {
      state = ImportFailed(
        message:
            added > 0
                ? '$added von ${cards.length} hinzugefügt, dann Fehler: $e'
                : '$e',
      );
      _autoReset(gen);
      rethrow;
    }
  }

  // ── Private helpers ───────────────────────────────────────────────

  /// Insert cards into a group. Pure DB work, no state management.
  Future<int> _insertCards({
    required String groupTitle,
    required List<PendingCard> cards,
    String? groupCoverUrl,
    String? tileId,
    void Function(int done, int total)? onProgress,
  }) async {
    final groupId =
        tileId ?? await _findOrCreateGroup(groupTitle, groupCoverUrl);
    final existingUris = ref.read(existingItemUrisProvider);

    var added = 0;
    for (var i = 0; i < cards.length; i++) {
      final card = cards[i];
      if (existingUris.contains(card.providerUri)) {
        await _assignExistingToGroup(
          card.providerUri,
          groupId,
          card.episodeNumber,
        );
      } else {
        await _insertCard(card, groupId: groupId);
        added++;
      }
      onProgress?.call(i + 1, cards.length);
    }

    Log.info(
      _tag,
      'Batch import complete',
      data: {
        'group': groupTitle,
        'added': '$added',
      },
    );

    return added;
  }

  Future<List<ArdItem>> _loadRemainingPages(
    ArdApi api,
    String showId,
    List<ArdItem> initial,
    String startCursor,
  ) async {
    final allItems = [...initial];
    String? cursor = startCursor;
    // Safety net: ARD shows rarely exceed 500 episodes. 100 pages at
    // 20 items/page = 2000 items, well above any real show.
    const maxPages = 100;
    var pageCount = 0;

    while (cursor != null && pageCount < maxPages) {
      final page = await api.getItems(programSetId: showId, after: cursor);
      allItems.addAll(page.items);
      cursor = page.hasNextPage ? page.endCursor : null;
      pageCount++;
    }

    if (pageCount >= maxPages && cursor != null) {
      Log.warn(
        _tag,
        'Pagination limit reached',
        data: {'showId': showId, 'pages': '$pageCount'},
      );
    }

    Log.debug(
      _tag,
      'All pages loaded',
      data: {
        'showId': showId,
        'total': '${allItems.length}',
      },
    );
    return allItems;
  }

  /// Reset to idle. Call from UI after handling ImportDone or ImportFailed.
  void acknowledge() {
    if (state is ImportDone || state is ImportFailed) {
      state = const ImportIdle();
    }
  }

  /// Auto-reset after 5s as safety net when no widget is listening.
  /// Uses a generation counter to avoid resetting a subsequent import.
  void _autoReset(int generation) {
    Future<void>.delayed(const Duration(seconds: 5), () {
      if (_generation == generation &&
          (state is ImportDone || state is ImportFailed)) {
        state = const ImportIdle();
      }
    });
  }

  Future<String> _findOrCreateGroup(String title, String? coverUrl) async {
    final existing = await _groupRepo.findByTitle(title);
    if (existing != null) {
      if (coverUrl != null) {
        await _groupRepo.update(id: existing.id, coverUrl: coverUrl);
      }
      return existing.id;
    }
    return _groupRepo.insert(title: title, coverUrl: coverUrl);
  }

  Future<void> _insertCard(PendingCard card, {String? groupId}) async {
    if (card.provider == ProviderType.ardAudiothek && card.audioUrl != null) {
      await _cardRepo.insertArdEpisode(
        title: card.title,
        providerUri: card.providerUri,
        audioUrl: card.audioUrl!,
        coverUrl: card.coverUrl,
        durationMs: card.durationMs,
        availableUntil: card.availableUntil,
        tileId: groupId,
        episodeNumber: card.episodeNumber,
      );
    } else {
      final cardId = await _cardRepo.insertIfAbsent(
        title: card.title,
        providerUri: card.providerUri,
        cardType: card.cardType,
        provider: card.provider,
        coverUrl: card.coverUrl,
        spotifyArtistIds: card.spotifyArtistIds,
        totalTracks: card.totalTracks,
      );
      if (groupId != null) {
        await _cardRepo.assignToTile(
          itemId: cardId,
          tileId: groupId,
          episodeNumber: card.episodeNumber,
        );
      }
    }
  }

  Future<void> _assignExistingToGroup(
    String providerUri,
    String groupId,
    int? episodeNumber,
  ) async {
    final card = await _cardRepo.getByProviderUri(providerUri);
    if (card != null && card.groupId != groupId) {
      await _cardRepo.updateArdFields(
        itemId: card.id,
        tileId: groupId,
        episodeNumber: episodeNumber,
      );
    }
  }
}
