import 'dart:async' show Timer;
import 'dart:isolate';

import 'package:bcrypt/bcrypt.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:lauschi/core/log.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'pin_service.g.dart';

const _tag = 'PinService';
const _pinHashKey = 'pin_hash';

const _defaultStorage = FlutterSecureStorage(
  iOptions: IOSOptions(
    accessibility: KeychainAccessibility.first_unlock_this_device,
  ),
);

/// Manages the parent-mode PIN (set, verify, check existence).
///
/// PIN is stored as a bcrypt hash in secure storage.
class PinService {
  PinService({FlutterSecureStorage? storage})
    : _storage = storage ?? _defaultStorage;

  final FlutterSecureStorage _storage;

  /// Whether a PIN has been set.
  Future<bool> hasPin() async {
    final hash = await _storage.read(key: _pinHashKey);
    return hash != null;
  }

  /// Minimum PIN length. 4 digits is standard for parental controls.
  static const minPinLength = 4;

  /// Set a new PIN. Hashes with bcrypt in a background isolate.
  Future<void> setPin(String pin) async {
    if (pin.length < minPinLength) {
      throw ArgumentError('PIN must be at least $minPinLength characters');
    }
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

/// How long a parent session stays active without interaction.
const _sessionTimeout = Duration(minutes: 15);

/// Whether a parent session started at [authenticatedAt] has expired as of
/// [now]. A null [authenticatedAt] counts as expired (no active session).
@visibleForTesting
bool isSessionExpired({
  required DateTime? authenticatedAt,
  required DateTime now,
}) {
  if (authenticatedAt == null) return true;
  return now.difference(authenticatedAt) >= _sessionTimeout;
}

/// Whether the user is currently authenticated in parent mode.
/// Resets when the app is closed or after [_sessionTimeout] of inactivity.
@Riverpod(keepAlive: true)
class ParentAuth extends _$ParentAuth {
  Timer? _expiryTimer;
  DateTime? _authenticatedAt;
  String? _lastTouchLocation;

  @override
  bool build() {
    ref.onDispose(() => _expiryTimer?.cancel());
    return false;
  }

  void authenticate() {
    Log.info(_tag, 'Parent authenticated');
    _authenticatedAt = DateTime.now();
    _lastTouchLocation = null;
    _resetTimer();
    state = true;
  }

  void deauthenticate() {
    Log.info(_tag, 'Parent deauthenticated');
    _expiryTimer?.cancel();
    _authenticatedAt = null;
    _lastTouchLocation = null;
    state = false;
  }

  /// Extend the session on genuine navigation to [location]. Repeated calls
  /// for the same location (router refreshes, e.g. a Spotify token refresh
  /// re-evaluating the redirect) are ignored, so background churn can't keep
  /// the session alive while the parent sits idle.
  void touch(String location) {
    if (!state) return;
    if (location == _lastTouchLocation) return;
    _lastTouchLocation = location;
    _authenticatedAt = DateTime.now();
    _resetTimer();
  }

  /// Re-check expiry against wall-clock time. Call on app resume: the Dart
  /// [_expiryTimer] can be frozen while the process is suspended, so a
  /// backgrounded session could otherwise outlive the timeout.
  void checkExpiry() {
    if (!state) return;
    if (isSessionExpired(
      authenticatedAt: _authenticatedAt,
      now: DateTime.now(),
    )) {
      Log.info(_tag, 'Parent session expired (wall-clock re-check)');
      deauthenticate();
    }
  }

  void _resetTimer() {
    _expiryTimer?.cancel();
    _expiryTimer = Timer(_sessionTimeout, () {
      if (state) {
        Log.info(_tag, 'Parent session expired after inactivity');
        state = false;
      }
    });
  }
}
