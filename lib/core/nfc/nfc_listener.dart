import 'dart:async' show unawaited;

import 'package:lauschi/core/database/card_repository.dart';
import 'package:lauschi/core/database/group_repository.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/nfc/nfc_service.dart';
import 'package:lauschi/core/settings/debug_settings.dart';
import 'package:lauschi/features/player/player_provider.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'nfc_listener.g.dart';

const _tag = 'NfcListener';

/// Background NFC listener that resolves scanned tags to playback actions.
///
/// Starts automatically when NFC is enabled in settings. Runs continuously
/// in foreground dispatch mode — each scan triggers a lookup and playback.
@Riverpod(keepAlive: true)
class NfcListener extends _$NfcListener {
  bool _listening = false;

  @override
  void build() {
    final settings = ref.watch(debugSettingsProvider);
    final nfcEnabled = settings.whenOrNull(data: (s) => s.nfcEnabled) ?? false;

    if (nfcEnabled && !_listening) {
      unawaited(_startListening());
    } else if (!nfcEnabled && _listening) {
      _stopListening();
    }
  }

  Future<void> _startListening() async {
    final nfc = ref.read(nfcServiceProvider);
    if (!await nfc.isAvailable) {
      Log.info(_tag, 'NFC not available on this device');
      return;
    }

    _listening = true;
    Log.info(_tag, 'NFC listener started');
    _listen();
  }

  void _listen() {
    if (!_listening) return;

    final nfc = ref.read(nfcServiceProvider);
    unawaited(
      nfc.startScan(
        onTagScanned: (tagUid) async {
          await _handleTag(tagUid);
          // Restart listening for the next tag.
          if (_listening) _listen();
        },
        onError: (error) {
          Log.warn(_tag, 'Scan error', data: {'error': error});
          // Restart listening after error.
          if (_listening) {
            Future<void>.delayed(
              const Duration(seconds: 1),
              () { if (_listening) _listen(); },
            );
          }
        },
      ),
    );
  }

  Future<void> _handleTag(String tagUid) async {
    final nfc = ref.read(nfcServiceProvider);
    final mapping = await nfc.resolve(tagUid);

    if (mapping == null) {
      Log.info(_tag, 'Unknown tag', data: {'uid': tagUid});
      return;
    }

    Log.info(
      _tag,
      'Tag resolved',
      data: {
        'uid': tagUid,
        'targetType': mapping.targetType,
        'targetId': mapping.targetId,
      },
    );

    final player = ref.read(playerProvider.notifier);

    if (mapping.targetType == 'group') {
      // Play the next unheard episode in the series.
      final groups = ref.read(groupRepositoryProvider);
      final nextCard = await groups.nextUnheard(mapping.targetId);
      if (nextCard != null) {
        await player.playCard(
          nextCard.providerUri,
          groupId: mapping.targetId,
        );
      } else {
        // All heard — play from the beginning (first episode).
        final allCards = await groups.watchCards(mapping.targetId).first;
        if (allCards.isNotEmpty) {
          await player.playCard(
            allCards.first.providerUri,
            groupId: mapping.targetId,
          );
        }
      }
    } else {
      // Play a single card.
      final cards = ref.read(cardRepositoryProvider);
      final card = await cards.getById(mapping.targetId);
      if (card != null) {
        await player.playCard(card.providerUri);
      }
    }
  }

  void _stopListening() {
    _listening = false;
    final nfc = ref.read(nfcServiceProvider);
    unawaited(nfc.stopScan());
    Log.info(_tag, 'NFC listener stopped');
  }
}
