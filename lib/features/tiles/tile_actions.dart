import 'dart:async' show unawaited;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lauschi/core/database/app_database.dart' as db;
import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/router/app_router.dart';
import 'package:lauschi/features/player/player_provider.dart';

/// Kid tapped a card: start it and open the player.
///
/// The full tap contract lives here so every grid behaves identically;
/// the same-card guard in [PlayerNotifier.playCard] keeps a re-tap of
/// the playing card from restarting audio, while navigation always
/// happens. NFC deliberately calls the bare [PlayerNotifier.playCard],
/// it has no screen to open.
void playCardAndOpenPlayer(
  BuildContext context,
  WidgetRef ref,
  db.TileItem card, {
  required String logTag,
  String? tileId,
}) {
  Log.info(
    logTag,
    'Card tapped',
    data: {
      'cardId': card.id,
      if (tileId != null) 'tileId': tileId,
      'title': card.customTitle ?? card.title,
    },
  );
  unawaited(ref.read(playerProvider.notifier).playCard(card.id));
  unawaited(context.push(AppRoutes.player));
}
