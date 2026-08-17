import 'dart:async' show unawaited;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:lauschi/core/database/tile_item_repository.dart';
import 'package:lauschi/core/database/tile_repository.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/nfc/nfc_service.dart';
import 'package:lauschi/core/settings/debug_settings.dart';
import 'package:lauschi/features/player/player_provider.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'nfc_listener.g.dart';

const _tag = 'NfcListener';

/// How long to ignore a repeat discovery of the same tag. Continuous reader
/// mode re-fires for a tag held in the field; without this, playback would
/// restart on every re-discovery.
const _rescanDebounce = Duration(seconds: 3);

/// Whether a scan of [uid] should be ignored as a duplicate: the same tag as
/// [lastUid], seen [sinceLast] ago, within [window].
@visibleForTesting
bool isDuplicateScan({
  required String uid,
  required String? lastUid,
  required Duration? sinceLast,
  Duration window = _rescanDebounce,
}) => uid == lastUid && sinceLast != null && sinceLast < window;

/// Background NFC listener that resolves scanned tags to playback actions.
///
/// Starts automatically when NFC is enabled in settings. Runs continuously
/// in foreground dispatch mode, each scan triggers a lookup and playback.
@Riverpod(keepAlive: true)
class NfcListener extends _$NfcListener {
  bool _listening = false;
  String? _lastHandledUid;
  DateTime? _lastHandledAt;

  @override
  void build() {
    final settings = ref.watch(debugSettingsProvider);
    final nfcEnabled = settings.whenOrNull(data: (s) => s.nfcEnabled) ?? false;

    if (nfcEnabled && !_listening) {
      // Claim the flag synchronously so a second build() during the async
      // start (settings re-emitting) can't kick off a second NFC session.
      _listening = true;
      unawaited(_startListening());
    } else if (!nfcEnabled && _listening) {
      _stopListening();
    }
  }

  Future<void> _startListening() async {
    final nfc = ref.read(nfcServiceProvider);
    if (!await nfc.isAvailable) {
      Log.info(_tag, 'NFC not available on this device');
      _listening = false;
      return;
    }

    Log.info(_tag, 'NFC listener started');

    try {
      await nfc.startContinuousScan(
        onTagScanned: (tagUid) => unawaited(_handleTag(tagUid)),
        onError: (error) {
          Log.warn(_tag, 'Scan error', data: {'error': error});
        },
      );
    } on Exception catch (e) {
      _listening = false;
      Log.error(_tag, 'Failed to start NFC scan', exception: e);
    }
  }

  Future<void> _handleTag(String tagUid) async {
    // Debounce a tag re-firing while held in the field, which would
    // otherwise restart playback on every re-discovery.
    final now = DateTime.now();
    final sinceLast =
        _lastHandledAt == null ? null : now.difference(_lastHandledAt!);
    if (isDuplicateScan(
      uid: tagUid,
      lastUid: _lastHandledUid,
      sinceLast: sinceLast,
    )) {
      return;
    }
    _lastHandledUid = tagUid;
    _lastHandledAt = now;

    try {
      final nfc = ref.read(nfcServiceProvider);
      final mapping = await nfc.resolve(tagUid);

      if (mapping == null) {
        Log.info(_tag, 'Unknown tag', data: {'uid': redactUid(tagUid)});
        return;
      }

      Log.info(
        _tag,
        'Tag resolved',
        data: {
          'uid': redactUid(tagUid),
          'targetType': mapping.targetType,
          'targetId': mapping.targetId,
        },
      );

      final player = ref.read(playerProvider.notifier);

      if (mapping.targetType == 'group') {
        // Play the next unheard episode in the series.
        final groups = ref.read(tileRepositoryProvider);
        final nextCard = await groups.nextUnheard(mapping.targetId);
        if (nextCard != null) {
          await player.playCard(nextCard.id);
        } else {
          // All heard, play from the beginning (first episode).
          final allCards = await groups.watchItems(mapping.targetId).first;
          if (allCards.isNotEmpty) {
            await player.playCard(allCards.first.id);
          }
        }
      } else {
        // Play a single card.
        final cards = ref.read(tileItemRepositoryProvider);
        final card = await cards.getById(mapping.targetId);
        if (card != null) {
          await player.playCard(card.id);
        }
      }
    } on Exception catch (e) {
      Log.error(
        _tag,
        'Failed to handle tag',
        exception: e,
        data: {'uid': redactUid(tagUid)},
      );
    }
  }

  void _stopListening() {
    _listening = false;
    final nfc = ref.read(nfcServiceProvider);
    unawaited(nfc.stopScan());
    Log.info(_tag, 'NFC listener stopped');
  }
}
