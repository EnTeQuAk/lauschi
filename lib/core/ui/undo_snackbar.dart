import 'package:flutter/material.dart';

/// App-level messenger key so an undo snackbar survives the screen pop that
/// some delete actions trigger (the edit screens navigate away right after
/// deleting). Set on the root [MaterialApp].
final rootScaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

/// How long an undo snackbar stays up before the action becomes permanent.
const undoWindow = Duration(seconds: 5);

/// Shows a floating snackbar with a "Rückgängig" action for [undoWindow].
///
/// [onUndo] runs only if the parent taps "Rückgängig" in time. Uses the app
/// messenger, so it works without a [BuildContext] and keeps showing after
/// the triggering screen is gone.
void showUndoSnackBar(String message, {required VoidCallback onUndo}) {
  final messenger = rootScaffoldMessengerKey.currentState;
  if (messenger == null) return;
  messenger
    ..clearSnackBars()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        duration: undoWindow,
        action: SnackBarAction(label: 'Rückgängig', onPressed: onUndo),
      ),
    );
}

/// Shows a plain floating snackbar via the app messenger, for the failure
/// side of an action whose success path shows [showUndoSnackBar].
void showAppSnackBar(String message) {
  rootScaffoldMessengerKey.currentState
    ?..clearSnackBars()
    ..showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
}
