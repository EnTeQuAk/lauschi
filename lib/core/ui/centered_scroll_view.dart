import 'dart:math' show max;

import 'package:flutter/widgets.dart';

/// Centers [child] in the available space when it fits, and scrolls it
/// when it doesn't, as on a short screen or with large system fonts.
class CenteredScrollView extends StatelessWidget {
  const CenteredScrollView({
    required this.child,
    this.padding = EdgeInsets.zero,
    super.key,
  });

  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder:
          (context, constraints) => SingleChildScrollView(
            padding: padding,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                // Zero in a window shorter than the padding, as in split
                // screen.
                minHeight: max(0, constraints.maxHeight - padding.vertical),
              ),
              child: Center(child: child),
            ),
          ),
    );
  }
}
