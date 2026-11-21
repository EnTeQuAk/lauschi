import 'dart:async' show unawaited;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Screens narrower than this on their short side are phones, the usual
/// tablet breakpoint.
const _tabletShortestSide = 600.0;

/// Keeps phones in portrait and lets tablets turn freely.
///
/// The lock needs the screen's size, which can still be zero while
/// `main()` runs at cold start. So it is applied after the first frame and
/// again whenever the metrics change, as when a foldable opens into a
/// tablet.
///
/// It goes by the app's view, since Flutter reports no display on Android
/// (-1 x -1 on a Pixel 9a with Android 16). A smaller view in split screen
/// makes no difference: Android and iPadOS ignore orientation requests in
/// split screen.
class PhonePortraitLock extends StatefulWidget {
  const PhonePortraitLock({required this.child, super.key});

  final Widget child;

  @override
  State<PhonePortraitLock> createState() => _PhonePortraitLockState();
}

class _PhonePortraitLockState extends State<PhonePortraitLock>
    with WidgetsBindingObserver {
  List<DeviceOrientation>? _applied;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance
      ..addObserver(this)
      ..addPostFrameCallback((_) => _apply());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeMetrics() => _apply();

  void _apply() {
    if (!mounted) return;
    final view = View.of(context);
    if (view.physicalSize.isEmpty) return;
    final shortestSide = view.physicalSize.shortestSide / view.devicePixelRatio;
    // An empty list lets the app take every orientation it declares.
    final orientations =
        shortestSide < _tabletShortestSide
            ? const [DeviceOrientation.portraitUp]
            : const <DeviceOrientation>[];
    if (listEquals(orientations, _applied)) return;
    _applied = orientations;
    unawaited(SystemChrome.setPreferredOrientations(orientations));
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
