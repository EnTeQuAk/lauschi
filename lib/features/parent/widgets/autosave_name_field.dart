import 'dart:async';

import 'package:flutter/material.dart';

/// How long typing has to pause before the name is saved.
const _saveDelay = Duration(milliseconds: 500);

/// A name field that saves itself while the parent types, the way a picked
/// cover does. It saves once typing pauses, on the keyboard's done key,
/// and when the screen goes away with a save still pending: on back, and
/// when the PIN screen replaces it because the session ended.
class AutosaveNameField extends StatefulWidget {
  const AutosaveNameField({
    required this.controller,
    required this.label,
    required this.onSave,
    this.hint,
    this.validate,
    super.key,
  });

  final TextEditingController controller;
  final String label;
  final String? hint;

  /// Stores the trimmed name. It can run after the screen is gone, so it
  /// must not touch the screen's state.
  final Future<void> Function(String name) onSave;

  /// The message for a trimmed name that can't be stored, or null when it
  /// can. A name with a message isn't saved.
  final String? Function(String name)? validate;

  @override
  State<AutosaveNameField> createState() => _AutosaveNameFieldState();
}

class _AutosaveNameFieldState extends State<AutosaveNameField> {
  Timer? _pendingSave;
  String? _error;

  @override
  void dispose() {
    // Children are disposed before their screen, so the controller still
    // holds the text here.
    _saveNow();
    super.dispose();
  }

  void _changed(String text) {
    _pendingSave?.cancel();
    _pendingSave = null;
    final error = widget.validate?.call(text.trim());
    if (error != _error) setState(() => _error = error);
    if (error == null) _pendingSave = Timer(_saveDelay, _save);
  }

  /// Runs a pending save right away.
  void _saveNow() {
    if (_pendingSave?.isActive != true) return;
    _pendingSave!.cancel();
    _save();
  }

  void _save() {
    _pendingSave = null;
    unawaited(widget.onSave(widget.controller.text.trim()));
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: widget.controller,
      decoration: InputDecoration(
        labelText: widget.label,
        hintText: widget.hint,
        errorText: _error,
      ),
      onChanged: _changed,
      onSubmitted: (_) => _saveNow(),
      textCapitalization: TextCapitalization.sentences,
    );
  }
}
