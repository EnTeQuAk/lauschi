import 'package:lauschi/core/database/tile_item_repository.dart';
import 'package:lauschi/core/database/tile_repository.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/providers/provider_type.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'content_importer.g.dart';

const _tag = 'ContentImporter';

/// A pending card to be imported. Provider-agnostic — both ARD and Spotify
/// screens build these from their respective data models.
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

/// Shared content import logic for all providers.
///
/// Handles find-or-create group, insert cards (skipping existing),
/// and state tracking. Screens build [PendingCard] lists from their
/// provider-specific models and call [importToGroup].
///
/// Per-item loading state (importingUris) is UI state and stays in screens.
/// This notifier handles only domain operations and batch progress.
@Riverpod(keepAlive: true)
class ContentImporter extends _$ContentImporter {
  @override
  bool build() => false; // true when a batch import is running

  TileItemRepository get _cardRepo => ref.read(tileItemRepositoryProvider);
  TileRepository get _groupRepo => ref.read(tileRepositoryProvider);

  /// Import cards into a group, creating it if needed.
  ///
  /// When [tileId] is set, cards are added directly to that tile
  /// (auto-assign mode). Otherwise, a group is found or created by title.
  ///
  /// [onProgress] is called after each card with (processed, total).
  ///
  /// Only one batch import at a time — concurrent calls are rejected.
  Future<ImportResult> importToGroup({
    required String groupTitle,
    required List<PendingCard> cards,
    String? groupCoverUrl,
    String? tileId,
    void Function(int done, int total)? onProgress,
  }) async {
    if (state) return ImportResult(added: 0, groupTitle: groupTitle);
    state = true;

    try {
      final groupId =
          tileId ?? await _findOrCreateGroup(groupTitle, groupCoverUrl);
      final existingUris = ref.read(existingItemUrisProvider);

      var added = 0;
      for (var i = 0; i < cards.length; i++) {
        final card = cards[i];
        if (existingUris.contains(card.providerUri)) {
          // Already exists — ensure it's in this group.
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
        data: {'group': groupTitle, 'added': '$added'},
      );

      return ImportResult(added: added, groupTitle: groupTitle);
    } finally {
      state = false;
    }
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
