import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lauschi/core/auth/pin_service.dart';
import 'package:lauschi/core/auth/pin_widgets.dart';
import 'package:lauschi/core/router/app_router.dart';
import 'package:lauschi/core/theme/app_theme.dart';

/// PIN entry screen for parent mode access.
///
/// Three modes:
/// - **verify**: Enter existing PIN to unlock parent mode.
/// - **setup**: Set a new PIN (first-time use).
/// - **change**: Verify current PIN, then set a new one.
class PinScreen extends ConsumerStatefulWidget {
  const PinScreen({super.key, this.isSetup = false, this.isChange = false});

  /// If true, prompts user to set a new PIN instead of verifying.
  final bool isSetup;

  /// If true, verifies the current PIN first, then allows setting a new one.
  final bool isChange;

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
  bool _changeVerified = false; // For change: current PIN verified

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

  bool get _isSettingUp =>
      widget.isSetup || (widget.isChange && _changeVerified);

  bool get _isConfirming => _isSettingUp && _firstPin != null;

  String get _title {
    if (widget.isChange && !_changeVerified) return 'Aktuelle PIN';
    if (_isSettingUp) {
      return _isConfirming ? 'PIN bestätigen' : 'Neue PIN festlegen';
    }
    return 'Eltern-Bereich';
  }

  String get _subtitle {
    if (widget.isChange && !_changeVerified) return 'Bitte zuerst bestätigen';
    if (_isSettingUp) {
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

      if (widget.isChange && !_changeVerified) {
        await _handleChangeVerify(pinStr);
      } else if (_isSettingUp) {
        await _handleSetup(pinStr);
      } else {
        await _handleVerify(pinStr);
      }
    }
  }

  Future<void> _handleChangeVerify(String pinStr) async {
    final pinService = ref.read(pinServiceProvider);
    final valid = await pinService.verifyPin(pinStr);

    if (valid) {
      setState(() {
        _changeVerified = true;
        _pin.clear();
      });
    } else {
      await _showError();
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
                key: const Key('pin_cancel'),
                onPressed: () {
                  if (context.canPop()) {
                    context.pop();
                  } else {
                    context.go(AppRoutes.kidHome);
                  }
                },
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
              child: PinDots(
                length: _pinLength,
                filled: _pin.length,
                hasError: _error,
              ),
            ),
            const SizedBox(height: AppSpacing.xxl),
            // Numpad
            PinNumpad(
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
