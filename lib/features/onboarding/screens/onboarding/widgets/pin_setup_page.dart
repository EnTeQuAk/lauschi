import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lauschi/core/auth/pin_service.dart';
import 'package:lauschi/core/auth/pin_widgets.dart';
import 'package:lauschi/core/theme/app_theme.dart';

/// PIN setup page for the onboarding flow.
class PinSetupPage extends ConsumerStatefulWidget {
  const PinSetupPage({required this.onComplete, super.key});
  final VoidCallback onComplete;

  @override
  ConsumerState<PinSetupPage> createState() => _PinSetupPageState();
}

class _PinSetupPageState extends ConsumerState<PinSetupPage> {
  final _pin = <int>[];
  String? _firstPin;
  bool _error = false;

  bool get _isConfirming => _firstPin != null;
  static const _pinLength = 4;

  Future<void> _onDigit(int digit) async {
    if (_pin.length >= _pinLength) return;

    setState(() {
      _pin.add(digit);
      _error = false;
    });

    if (_pin.length < _pinLength) return;

    final pinStr = _pin.map((d) => d.toString()).join();

    if (_firstPin == null) {
      setState(() {
        _firstPin = pinStr;
        _pin.clear();
      });
    } else if (_firstPin == pinStr) {
      final pinService = ref.read(pinServiceProvider);
      await pinService.setPin(pinStr);
      widget.onComplete();
    } else {
      setState(() {
        _firstPin = null;
        _pin.clear();
        _error = true;
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
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.lock_open_rounded,
            size: 48,
            color: AppColors.primary,
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            _isConfirming ? 'PIN bestätigen' : 'Eltern-PIN festlegen',
            style: const TextStyle(
              fontFamily: 'Nunito',
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            _isConfirming ? 'Nochmal eingeben' : 'Wähle eine 4-stellige PIN',
            style: const TextStyle(
              fontFamily: 'Nunito',
              fontSize: 15,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: AppSpacing.xl),
          PinDots(
            length: _pinLength,
            filled: _pin.length,
            hasError: _error,
          ),
          if (_error) ...[
            const SizedBox(height: AppSpacing.sm),
            const Text(
              'PINs stimmen nicht überein',
              style: TextStyle(
                fontFamily: 'Nunito',
                fontSize: 13,
                color: AppColors.error,
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.xl),
          PinNumpad(
            onDigit: _onDigit,
            onBackspace: _onBackspace,
          ),
        ],
      ),
    );
  }
}
