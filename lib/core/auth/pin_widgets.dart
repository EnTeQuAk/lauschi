import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:lauschi/core/theme/app_theme.dart';

/// Animated PIN dots showing how many digits have been entered.
class PinDots extends StatelessWidget {
  const PinDots({
    required this.length,
    required this.filled,
    super.key,
    this.hasError = false,
  });

  final int length;
  final int filled;
  final bool hasError;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(length, (index) {
        final isFilled = index < filled;
        final color =
            hasError
                ? AppColors.error
                : isFilled
                ? AppColors.primary
                : AppColors.surfaceDim;

        return AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          margin: const EdgeInsets.symmetric(horizontal: 6),
          width: 16,
          height: 16,
          decoration: BoxDecoration(shape: BoxShape.circle, color: color),
        );
      }),
    );
  }
}

/// 3×4 numpad grid with circular buttons and haptic feedback.
class PinNumpad extends StatelessWidget {
  const PinNumpad({
    required this.onDigit,
    required this.onBackspace,
    super.key,
  });

  final void Function(int digit) onDigit;
  final VoidCallback onBackspace;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      child: Column(
        children: [
          for (final row in _rows)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: row.map(_buildKey).toList(),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildKey(_NumpadKey key) {
    switch (key) {
      case _DigitKey(:final digit):
        return _NumpadButton(
          onTap: () => onDigit(digit),
          child: Text(
            '$digit',
            style: const TextStyle(
              fontFamily: 'Nunito',
              fontWeight: FontWeight.w700,
              fontSize: 22,
              color: AppColors.textPrimary,
            ),
          ),
        );
      case _BackspaceKey():
        return Semantics(
          label: 'Löschen',
          button: true,
          child: _NumpadButton(
            onTap: onBackspace,
            child: const Icon(
              Icons.backspace_outlined,
              color: AppColors.textPrimary,
            ),
          ),
        );
      case _EmptyKey():
        return const SizedBox(width: 72, height: 72);
    }
  }

  static final List<List<_NumpadKey>> _rows = [
    [_DigitKey(1), _DigitKey(2), _DigitKey(3)],
    [_DigitKey(4), _DigitKey(5), _DigitKey(6)],
    [_DigitKey(7), _DigitKey(8), _DigitKey(9)],
    [_EmptyKey(), _DigitKey(0), _BackspaceKey()],
  ];
}

/// 72dp circular button for the numpad.
///
/// Hit area is the full 72x72 bounding box (not clipped to the circle)
/// so that automated touch injection via adb or Patrol works reliably.
/// The ink splash still follows the circular shape.
class _NumpadButton extends StatelessWidget {
  const _NumpadButton({required this.onTap, required this.child});

  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 72,
      height: 72,
      child: Material(
        color: AppColors.surface,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () {
            unawaited(HapticFeedback.lightImpact());
            onTap();
          },
          child: Center(child: child),
        ),
      ),
    );
  }
}

sealed class _NumpadKey {}

class _DigitKey extends _NumpadKey {
  _DigitKey(this.digit);
  final int digit;
}

class _BackspaceKey extends _NumpadKey {}

class _EmptyKey extends _NumpadKey {}
