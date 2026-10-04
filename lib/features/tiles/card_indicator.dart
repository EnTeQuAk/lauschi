/// What a card on a kid grid shows: its status, whether it carries the
/// Weiter badge, and its progress bar.
///
/// Decided here and nowhere else, so every grid shows the same card the
/// same way. Widgets render the result and never combine flags.
library;

import 'package:lauschi/core/database/app_database.dart';
import 'package:lauschi/core/database/tile_item_repository.dart';
import 'package:lauschi/features/player/player_provider.dart'
    show PlayerGridState;

/// Exactly one per card, in order of precedence.
enum CardStatus {
  /// The content is gone. Greyed out, a tap explains why.
  unavailable,

  /// In the player, waiting for audio.
  starting,

  /// In the player, playing.
  playing,

  /// In the player, paused before its end.
  paused,

  /// Heard before (and not playing right now).
  heard,

  /// Nothing of the above.
  fresh,
}

typedef CardIndicator =
    ({
      CardStatus status,

      /// The tile continues with this card.
      bool isWeiter,

      /// How far into the card its resume point is, 0.0–1.0.
      double progress,
    });

/// The indicator for [card], given the [player] and the id of its tile's
/// Weiter item ([weiterId], null outside a tile).
///
/// Only the card in the player (`PlayerGridState.activeCardId`) can be
/// starting, playing or paused. Once it is finished and no longer
/// playing, it shows as heard like any other finished card.
CardIndicator cardIndicator(
  TileItem card, {
  required PlayerGridState player,
  String? weiterId,
}) {
  final status = _status(card, player);
  return (
    status: status,
    isWeiter: status != CardStatus.unavailable && card.id == weiterId,
    progress:
        status == CardStatus.unavailable || status == CardStatus.heard
            ? 0
            : albumProgress(card),
  );
}

CardStatus _status(TileItem card, PlayerGridState player) {
  if (isItemUnavailable(card)) return CardStatus.unavailable;
  final inPlayer = player.track != null && player.activeCardId == card.id;
  if (inPlayer) {
    if (player.isLoading) return CardStatus.starting;
    if (player.isPlaying) return CardStatus.playing;
    if (!player.isFinished) return CardStatus.paused;
  }
  return card.isHeard ? CardStatus.heard : CardStatus.fresh;
}

typedef TileIndicator =
    ({
      /// Playable items in the tile (playlist tracks counted singly).
      int episodeCount,

      /// Share of the playable items heard, 0.0–1.0.
      double progress,

      /// The tile has items and none of them is playable.
      bool isUnavailable,
    });

/// The indicator for a series tile, from its [computeTileProgress] entry
/// ([stats], null for a tile without items).
TileIndicator tileIndicator(({int total, int heard})? stats) {
  final total = stats?.total ?? 0;
  return (
    episodeCount: total,
    progress: total > 0 ? stats!.heard / total : 0,
    isUnavailable: isTileFullyUnavailable(stats),
  );
}
