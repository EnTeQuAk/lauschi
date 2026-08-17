import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lauschi/core/auth/pin_service.dart';
import 'package:lauschi/core/auth/pin_widgets.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/theme/app_theme.dart';

const _tag = 'PinSetupPage';

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
  String? _errorMessage;
  bool _saving = false;

  bool get _isConfirming => _firstPin != null;
  static const _pinLength = 4;

  Future<void> _onDigit(int digit) async {
    if (_saving || _pin.length >= _pinLength) return;

    setState(() {
      _pin.add(digit);
      _errorMessage = null;
    });

    if (_pin.length < _pinLength) return;

    final pinStr = _pin.map((d) => d.toString()).join();

    if (_firstPin == null) {
      setState(() {
        _firstPin = pinStr;
        _pin.clear();
      });
    } else if (_firstPin == pinStr) {
      // Persist the PIN. setPin runs bcrypt in an isolate (slow), so show a
      // spinner; a secure-storage failure must reset instead of trapping the
      // parent on four filled dots with no feedback.
      setState(() => _saving = true);
      try {
        await ref.read(pinServiceProvider).setPin(pinStr);
      } on Object catch (e) {
        Log.error(_tag, 'PIN setup failed', exception: e);
        if (mounted) {
          setState(() {
            _saving = false;
            _pin.clear();
            _firstPin = null;
            _errorMessage = 'Speichern fehlgeschlagen, bitte erneut versuchen';
          });
        }
        return;
      }
      if (mounted) widget.onComplete();
    } else {
      setState(() {
        _firstPin = null;
        _pin.clear();
        _errorMessage = 'PINs stimmen nicht überein';
      });
    }
  }

  void _onBackspace() {
    if (_saving || _pin.isEmpty) return;
    setState(() {
      _pin.removeLast();
      _errorMessage = null;
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
            hasError: _errorMessage != null,
          ),
          if (_errorMessage != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              _errorMessage!,
              style: const TextStyle(
                fontFamily: 'Nunito',
                fontSize: 13,
                color: AppColors.error,
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.xl),
          if (_saving)
            const CircularProgressIndicator()
          else
            PinNumpad(
              onDigit: _onDigit,
              onBackspace: _onBackspace,
            ),
        ],
      ),
    );
  }
}
