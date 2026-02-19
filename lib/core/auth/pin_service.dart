import 'dart:isolate';

import 'package:bcrypt/bcrypt.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:lauschi/core/log.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'pin_service.g.dart';

const _tag = 'PinService';
const _pinHashKey = 'pin_hash';

/// Manages the parent-mode PIN (set, verify, check existence).
///
/// PIN is stored as a bcrypt hash in secure storage.
class PinService {
  PinService({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  /// Whether a PIN has been set.
  Future<bool> hasPin() async {
    final hash = await _storage.read(key: _pinHashKey);
    return hash != null;
  }

  /// Set a new PIN. Hashes with bcrypt in a background isolate.
  Future<void> setPin(String pin) async {
    final hash = await Isolate.run(
      () => BCrypt.hashpw(pin, BCrypt.gensalt()),
    );
    await _storage.write(key: _pinHashKey, value: hash);
    Log.info(_tag, 'PIN set');
  }

  /// Verify a PIN against the stored hash in a background isolate.
  Future<bool> verifyPin(String pin) async {
    final hash = await _storage.read(key: _pinHashKey);
    if (hash == null) return false;
    final match = await Isolate.run(() => BCrypt.checkpw(pin, hash));
    Log.debug(_tag, 'PIN verification', data: {'match': '$match'});
    return match;
  }

  /// Remove the stored PIN.
  Future<void> clearPin() async {
    await _storage.delete(key: _pinHashKey);
    Log.info(_tag, 'PIN cleared');
  }
}

@Riverpod(keepAlive: true)
PinService pinService(Ref ref) => PinService();

/// Whether the user is currently authenticated in parent mode.
/// Resets when the app is closed. Not persisted.
@Riverpod(keepAlive: true)
class ParentAuth extends _$ParentAuth {
  @override
  bool build() => false;

  void authenticate() => state = true;
  void deauthenticate() => state = false;
}
