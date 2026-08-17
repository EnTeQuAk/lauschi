import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:lauschi/core/log.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'connectivity_provider.g.dart';

const _tag = 'Connectivity';

/// Whether the device currently has network connectivity.
///
/// Watches [Connectivity] stream and emits true/false.
@Riverpod(keepAlive: true)
class IsOnline extends _$IsOnline {
  StreamSubscription<List<ConnectivityResult>>? _sub;
  bool _disposed = false;

  @override
  bool build() {
    _disposed = false;
    unawaited(_sub?.cancel());
    _sub = Connectivity().onConnectivityChanged.listen(_onChanged);
    ref.onDispose(() {
      _disposed = true;
      unawaited(_sub?.cancel());
    });

    // Assume online until first check
    unawaited(_check());
    return true;
  }

  Future<void> _check() async {
    final result = await Connectivity().checkConnectivity();
    _onChanged(result);
  }

  void _onChanged(List<ConnectivityResult> results) {
    // The initial _check() and a queued stream event can resolve after the
    // provider is disposed; don't touch state then.
    if (_disposed) return;
    final online = results.any((r) => r != ConnectivityResult.none);
    if (online != state) {
      Log.info(_tag, online ? 'Online' : 'Offline');
      state = online;
    }
  }
}
