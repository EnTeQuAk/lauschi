import 'dart:async' show unawaited;
import 'dart:io' show Platform;

import 'package:drift/drift.dart';
import 'package:lauschi/core/database/app_database.dart' as db;
import 'package:lauschi/core/database/app_database.dart'
    show appDatabaseProvider;
import 'package:lauschi/core/log.dart';
import 'package:nfc_manager/nfc_manager.dart';
import 'package:nfc_manager/nfc_manager_android.dart';
import 'package:nfc_manager/nfc_manager_ios.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'nfc_service.g.dart';

const _tag = 'NfcService';

/// Manages NFC tag ↔ content mappings using hardware UIDs.
///
/// UID-based approach: we read the tag's unique hardware ID and map it
/// to a group or card in the local database. No NDEF write needed — works
/// with any NFC chip type (NTAG, iCode SLIX, Mifare, etc.).
class NfcService {
  NfcService(this._db);

  final db.AppDatabase _db;

  /// Whether this device has NFC hardware and it's enabled.
  Future<bool> get isAvailable async {
    final availability = await NfcManager.instance.checkAvailability();
    return availability == NfcAvailability.enabled;
  }

  // ---------------------------------------------------------------------------
  // Tag mappings
  // ---------------------------------------------------------------------------

  /// All stored tag mappings.
  Future<List<db.NfcTag>> getAll() {
    return _db.select(_db.nfcTags).get();
  }

  /// Watch all mappings (for reactive UI).
  Stream<List<db.NfcTag>> watchAll() {
    return _db.select(_db.nfcTags).watch();
  }

  /// Look up what a tag UID maps to. Returns null for unknown tags.
  Future<db.NfcTag?> resolve(String tagUid) {
    return (_db.select(_db.nfcTags)
      ..where((t) => t.tagUid.equals(tagUid))).getSingleOrNull();
  }

  /// Store a tag mapping (scan tag → store UID → content link).
  ///
  /// If the UID already exists, updates the target.
  Future<void> writeMapping({
    required String tagUid,
    required String targetType,
    required String targetId,
    String? label,
  }) async {
    final companion = db.NfcTagsCompanion.insert(
      tagUid: tagUid,
      targetType: targetType,
      targetId: targetId,
      label: Value(label),
    );
    await _db.into(_db.nfcTags).insert(
      companion,
      onConflict: DoUpdate(
        (old) => db.NfcTagsCompanion(
          targetType: Value(targetType),
          targetId: Value(targetId),
          label: Value(label),
        ),
        target: [_db.nfcTags.tagUid],
      ),
    );
    Log.info(
      _tag,
      'Tag mapped',
      data: {
        'uid': tagUid,
        'targetType': targetType,
        'targetId': targetId,
      },
    );
  }

  /// Delete a tag mapping.
  Future<void> deleteMapping(String tagUid) async {
    await (_db.delete(_db.nfcTags)..where((t) => t.tagUid.equals(tagUid))).go();
    Log.info(_tag, 'Tag mapping deleted', data: {'uid': tagUid});
  }

  // ---------------------------------------------------------------------------
  // NFC hardware interaction
  // ---------------------------------------------------------------------------

  /// One-shot scan: discover a single tag, then stop the session.
  ///
  /// Used by the pairing dialog where we want exactly one tag.
  Future<void> startScan({
    required void Function(String tagUid) onTagScanned,
    void Function(String error)? onError,
  }) async {
    if (!await isAvailable) {
      onError?.call('NFC nicht verfügbar');
      return;
    }

    unawaited(
      NfcManager.instance.startSession(
        pollingOptions: {NfcPollingOption.iso14443, NfcPollingOption.iso15693},
        onDiscovered: (tag) async {
          final uid = _extractUid(tag);
          if (uid == null) {
            onError?.call('Tag-UID nicht lesbar');
            unawaited(NfcManager.instance.stopSession());
            return;
          }
          Log.info(_tag, 'Tag scanned (one-shot)', data: {'uid': uid});
          onTagScanned(uid);
          unawaited(NfcManager.instance.stopSession());
        },
      ),
    );
  }

  /// Continuous reader mode: keeps the session open and fires [onTagScanned]
  /// for every tag discovered. Does NOT stop between scans — this prevents
  /// Android's default tag dispatch from taking over (screen flash, etc.).
  ///
  /// Call [stopScan] to end the session.
  Future<void> startContinuousScan({
    required void Function(String tagUid) onTagScanned,
    void Function(String error)? onError,
  }) async {
    if (!await isAvailable) {
      onError?.call('NFC nicht verfügbar');
      return;
    }

    unawaited(
      NfcManager.instance.startSession(
        pollingOptions: {NfcPollingOption.iso14443, NfcPollingOption.iso15693},
        onDiscovered: (tag) async {
          final uid = _extractUid(tag);
          if (uid == null) {
            Log.warn(_tag, 'Tag UID not readable');
            return;
          }
          Log.info(_tag, 'Tag scanned', data: {'uid': uid});
          onTagScanned(uid);
          // Session stays open — reader mode remains active.
        },
      ),
    );
  }

  /// Stop any active NFC scan session.
  Future<void> stopScan() async {
    await NfcManager.instance.stopSession();
  }

  /// Extract the hardware UID from an NFC tag as a hex string.
  ///
  /// Android: reads from [NfcTagAndroid.id].
  /// iOS: tries MiFare (NTAG215 stickers), ISO 7816, then ISO 15693.
  static String? _extractUid(NfcTag tag) {
    final Uint8List? id;

    if (Platform.isAndroid) {
      id = NfcTagAndroid.from(tag)?.id;
    } else if (Platform.isIOS) {
      // NTAG215/NTAG213 stickers are MiFare Ultralight on iOS.
      id = MiFareIos.from(tag)?.identifier ??
          Iso7816Ios.from(tag)?.identifier ??
          Iso15693Ios.from(tag)?.identifier;
    } else {
      return null;
    }

    if (id == null || id.isEmpty) return null;
    return id.map((b) => b.toRadixString(16).padLeft(2, '0')).join(':');
  }
}

@Riverpod(keepAlive: true)
NfcService nfcService(Ref ref) {
  return NfcService(ref.watch(appDatabaseProvider));
}
