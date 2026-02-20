import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lauschi/core/nfc/nfc_service.dart';
import 'package:lauschi/core/theme/app_theme.dart';

/// Shows a dialog that scans for an NFC tag and maps it to the given target.
///
/// Returns true if a tag was successfully paired, false otherwise.
Future<bool> showNfcPairDialog(
  BuildContext context, {
  required WidgetRef ref,
  required String targetType,
  required String targetId,
  required String targetLabel,
}) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder:
        (_) => _NfcPairDialog(
          ref: ref,
          targetType: targetType,
          targetId: targetId,
          targetLabel: targetLabel,
        ),
  );
  return result ?? false;
}

class _NfcPairDialog extends StatefulWidget {
  const _NfcPairDialog({
    required this.ref,
    required this.targetType,
    required this.targetId,
    required this.targetLabel,
  });

  final WidgetRef ref;
  final String targetType;
  final String targetId;
  final String targetLabel;

  @override
  State<_NfcPairDialog> createState() => _NfcPairDialogState();
}

enum _PairState { scanning, success, error }

class _NfcPairDialogState extends State<_NfcPairDialog> {
  _PairState _state = _PairState.scanning;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    unawaited(_startScan());
  }

  @override
  void dispose() {
    unawaited(widget.ref.read(nfcServiceProvider).stopScan());
    super.dispose();
  }

  Future<void> _startScan() async {
    final nfc = widget.ref.read(nfcServiceProvider);

    await nfc.startScan(
      onTagScanned: (tagUid) async {
        await nfc.writeMapping(
          tagUid: tagUid,
          targetType: widget.targetType,
          targetId: widget.targetId,
          label: widget.targetLabel,
        );
        if (mounted) {
          setState(() => _state = _PairState.success);
          // Auto-close after brief success display
          await Future<void>.delayed(const Duration(milliseconds: 1200));
          if (mounted) Navigator.of(context).pop(true);
        }
      },
      onError: (error) {
        if (mounted) {
          setState(() {
            _state = _PairState.error;
            _errorMessage = error;
          });
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        switch (_state) {
          _PairState.scanning => 'NFC-Tag scannen',
          _PairState.success => 'Verknüpft!',
          _PairState.error => 'Fehler',
        },
        style: const TextStyle(
          fontFamily: 'Nunito',
          fontWeight: FontWeight.w700,
        ),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            switch (_state) {
              _PairState.scanning => Icons.nfc_rounded,
              _PairState.success => Icons.check_circle_rounded,
              _PairState.error => Icons.error_outline_rounded,
            },
            size: 56,
            color: switch (_state) {
              _PairState.scanning => AppColors.primary,
              _PairState.success => AppColors.success,
              _PairState.error => AppColors.error,
            },
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            switch (_state) {
              _PairState.scanning =>
                'Halte den NFC-Tag an dein Gerät, '
                    'um ihn mit „${widget.targetLabel}" zu verknüpfen.',
              _PairState.success =>
                '„${widget.targetLabel}" mit NFC-Tag verknüpft.',
              _PairState.error => _errorMessage ?? 'Unbekannter Fehler',
            },
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontFamily: 'Nunito',
              fontSize: 14,
              color: AppColors.textSecondary,
            ),
          ),
          if (_state == _PairState.scanning) ...[
            const SizedBox(height: AppSpacing.lg),
            const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ],
        ],
      ),
      actions: [
        if (_state != _PairState.success)
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Abbrechen'),
          ),
        if (_state == _PairState.error)
          TextButton(
            onPressed: () {
              setState(() => _state = _PairState.scanning);
              unawaited(_startScan());
            },
            child: const Text('Nochmal'),
          ),
      ],
    );
  }
}
