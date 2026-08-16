import 'dart:async';

/// One flushed batch of rapid catalog adds, snapshotted for the snackbar.
class AddSnackBatch {
  const AddSnackBatch({
    required this.cardIds,
    required this.undoable,
    this.seriesTitle,
    this.firstAlbumName,
  });

  /// Ids of the cards added in this batch, in add order — the exact set
  /// the snackbar's undo removes.
  final List<String> cardIds;

  /// Whether the snackbar offers an undo action.
  final bool undoable;

  /// Series title when every add in the batch shares one curated series;
  /// null for the plain-count batch (auto-assign or unmatched adds).
  final String? seriesTitle;

  /// First album's name, to label a single plain-count add.
  final String? firstAlbumName;
}

/// Batches rapid catalog adds into a single snackbar.
///
/// Adds that arrive within [_window] of each other collapse into one
/// snackbar. An add that can't share the pending batch's snackbar — a
/// different series, or an undoable add vs a plain one — flushes the
/// current batch first and starts a new one. That keeps each undo scoped
/// to exactly the cards its own snackbar names, instead of one timer and
/// one bucket letting the two add paths corrupt each other.
class AddSnackQueue {
  AddSnackQueue({required this.onFlush});

  /// Called with a completed batch, on the flush timer or when an
  /// incompatible add forces an early flush.
  final void Function(AddSnackBatch batch) onFlush;

  static const _window = Duration(milliseconds: 500);

  final _cardIds = <String>[];
  bool _undoable = false;
  String? _seriesTitle;
  String? _firstAlbumName;
  Timer? _timer;

  void add({
    required String cardId,
    required String albumName,
    required bool undoable,
    String? seriesTitle,
  }) {
    final incompatible =
        _cardIds.isNotEmpty &&
        (_undoable != undoable || _seriesTitle != seriesTitle);
    if (incompatible) flush();

    if (_cardIds.isEmpty) {
      _undoable = undoable;
      _seriesTitle = seriesTitle;
      _firstAlbumName = albumName;
    }
    _cardIds.add(cardId);

    _timer?.cancel();
    _timer = Timer(_window, flush);
  }

  /// Emit the pending batch now, if any, and clear it.
  void flush() {
    _timer?.cancel();
    if (_cardIds.isEmpty) return;

    final batch = AddSnackBatch(
      cardIds: List.of(_cardIds),
      undoable: _undoable,
      seriesTitle: _seriesTitle,
      firstAlbumName: _firstAlbumName,
    );
    _cardIds.clear();
    _seriesTitle = null;
    _firstAlbumName = null;

    onFlush(batch);
  }

  void dispose() => _timer?.cancel();
}
