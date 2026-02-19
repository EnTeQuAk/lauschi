import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lauschi/core/auth/pin_service.dart';
import 'package:lauschi/core/router/app_router.dart';
import 'package:lauschi/core/theme/app_theme.dart';

/// PIN entry screen for parent mode access.
///
/// Two modes:
/// - **verify**: Enter existing PIN to unlock parent mode.
/// - **setup**: Set a new PIN (first-time use or change).
class PinScreen extends ConsumerStatefulWidget {
  const PinScreen({super.key, this.isSetup = false});

  /// If true, prompts user to set a new PIN instead of verifying.
  final bool isSetup;

  @override
  ConsumerState<PinScreen> createState() => _PinScreenState();
}

class _PinScreenState extends ConsumerState<PinScreen>
    with SingleTickerProviderStateMixin {
  final _pin = <int>[];
  late final AnimationController _shakeController;
  late final Animation<double> _shakeAnimation;
  bool _error = false;
  String? _firstPin; // For setup: stores first entry to confirm

  static const _pinLength = 4;

  @override
  void initState() {
    super.initState();
    _shakeController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _shakeAnimation = Tween<double>(begin: 0, end: 12).animate(
      CurvedAnimation(parent: _shakeController, curve: Curves.elasticIn),
    );
  }

  @override
  void dispose() {
    _shakeController.dispose();
    super.dispose();
  }

  bool get _isConfirming => widget.isSetup && _firstPin != null;

  String get _title {
    if (widget.isSetup) {
      return _isConfirming ? 'PIN bestätigen' : 'PIN festlegen';
    }
    return 'Eltern-Bereich';
  }

  String get _subtitle {
    if (widget.isSetup) {
      return _isConfirming ? 'Nochmal eingeben' : 'Wähle eine 4-stellige PIN';
    }
    return 'PIN eingeben';
  }

  Future<void> _onDigit(int digit) async {
    if (_pin.length >= _pinLength) return;

    setState(() {
      _pin.add(digit);
      _error = false;
    });

    if (_pin.length == _pinLength) {
      final pinStr = _pin.map((d) => d.toString()).join();

      if (widget.isSetup) {
        await _handleSetup(pinStr);
      } else {
        await _handleVerify(pinStr);
      }
    }
  }

  Future<void> _handleVerify(String pinStr) async {
    final pinService = ref.read(pinServiceProvider);
    final valid = await pinService.verifyPin(pinStr);

    if (valid) {
      ref.read(parentAuthProvider.notifier).authenticate();
      if (mounted) {
        context.go(AppRoutes.parentDashboard);
      }
    } else {
      await _showError();
    }
  }

  Future<void> _handleSetup(String pinStr) async {
    if (_firstPin == null) {
      // First entry — store and ask for confirmation
      setState(() {
        _firstPin = pinStr;
        _pin.clear();
      });
    } else if (_firstPin == pinStr) {
      // Confirmation matches — save
      final pinService = ref.read(pinServiceProvider);
      await pinService.setPin(pinStr);
      ref.read(parentAuthProvider.notifier).authenticate();
      if (mounted) {
        context.go(AppRoutes.parentDashboard);
      }
    } else {
      // Mismatch — restart
      _firstPin = null;
      await _showError();
    }
  }

  Future<void> _showError() async {
    unawaited(HapticFeedback.heavyImpact());
    setState(() => _error = true);
    await _shakeController.forward();
    await _shakeController.reverse();
    if (mounted) {
      setState(() {
        _pin.clear();
        _error = false;
      });
    }
  }

  void _onBackspace() {
    if (_pin.isEmpty) return;
    setState(() {
      _pin.removeLast();
      _error = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // Cancel button
            Align(
              alignment: Alignment.topLeft,
              child: TextButton(
                onPressed: () => context.pop(),
                child: const Text('Abbrechen'),
              ),
            ),
            const Spacer(),
            // Lock icon
            Icon(
              widget.isSetup ? Icons.lock_open_rounded : Icons.lock_rounded,
              size: 48,
              color: AppColors.primary,
            ),
            const SizedBox(height: AppSpacing.md),
            // Title
            Text(
              _title,
              style: const TextStyle(
                fontFamily: 'Nunito',
                fontSize: 24,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            // Subtitle
            Text(
              _subtitle,
              style: const TextStyle(
                fontFamily: 'Nunito',
                fontSize: 15,
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: AppSpacing.xl),
            // PIN dots
            AnimatedBuilder(
              animation: _shakeAnimation,
              builder: (context, child) {
                final offset =
                    _shakeAnimation.value *
                    (_shakeController.status == AnimationStatus.forward
                        ? 1
                        : -1);
                return Transform.translate(
                  offset: Offset(offset, 0),
                  child: child,
                );
              },
              child: _PinDots(
                length: _pinLength,
                filled: _pin.length,
                hasError: _error,
              ),
            ),
            const SizedBox(height: AppSpacing.xxl),
            // Numpad
            _Numpad(
              onDigit: _onDigit,
              onBackspace: _onBackspace,
            ),
            const Spacer(),
          ],
        ),
      ),
    );
  }
}

class _PinDots extends StatelessWidget {
  const _PinDots({
    required this.length,
    required this.filled,
    required this.hasError,
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
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color,
          ),
        );
      }),
    );
  }
}

class _Numpad extends StatelessWidget {
  const _Numpad({
    required this.onDigit,
    required this.onBackspace,
  });

  final void Function(int digit) onDigit;
  final VoidCallback onBackspace;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xxl),
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
        return _NumpadButton(
          onTap: onBackspace,
          child: const Icon(
            Icons.backspace_outlined,
            color: AppColors.textPrimary,
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
class _NumpadButton extends StatelessWidget {
  const _NumpadButton({
    required this.onTap,
    required this.child,
  });

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
        clipBehavior: Clip.antiAlias,
        child: InkWell(
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
