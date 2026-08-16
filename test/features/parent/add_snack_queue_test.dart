import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/features/parent/screens/browse_catalog/add_snack_queue.dart';

void main() {
  group('AddSnackQueue', () {
    test('batches same-series undoable adds into one snackbar', () {
      fakeAsync((async) {
        final flushed = <AddSnackBatch>[];
        final queue = AddSnackQueue(onFlush: flushed.add)..add(
          cardId: 'a',
          albumName: 'Folge 1',
          undoable: true,
          seriesTitle: 'TKKG',
        );

        async.elapse(const Duration(milliseconds: 100));
        queue.add(
          cardId: 'b',
          albumName: 'Folge 2',
          undoable: true,
          seriesTitle: 'TKKG',
        );
        async.elapse(const Duration(milliseconds: 600));

        expect(flushed, hasLength(1));
        expect(flushed.single.cardIds, ['a', 'b']);
        expect(flushed.single.seriesTitle, 'TKKG');
        expect(flushed.single.undoable, isTrue);
      });
    });

    test('a different series flushes the first batch before the second', () {
      // The bug this guards: collapsing two series under one undo removed
      // the wrong cards. Each series must land in its own batch.
      fakeAsync((async) {
        final flushed = <AddSnackBatch>[];
        final queue = AddSnackQueue(onFlush: flushed.add)..add(
          cardId: 'a',
          albumName: 'TKKG 1',
          undoable: true,
          seriesTitle: 'TKKG',
        );

        async.elapse(const Duration(milliseconds: 100));
        queue.add(
          cardId: 'b',
          albumName: 'Bibi 1',
          undoable: true,
          seriesTitle: 'Bibi',
        );
        async.elapse(const Duration(milliseconds: 600));

        expect(flushed, hasLength(2));
        expect(flushed[0].cardIds, ['a']);
        expect(flushed[0].seriesTitle, 'TKKG');
        expect(flushed[1].cardIds, ['b']);
        expect(flushed[1].seriesTitle, 'Bibi');
      });
    });

    test('an undoable add and a plain add do not share a batch', () {
      // The bug this guards: a plain add cancelled the undo batch's timer,
      // leaking its ids into the next undo. They must flush separately.
      fakeAsync((async) {
        final flushed = <AddSnackBatch>[];
        final queue = AddSnackQueue(onFlush: flushed.add)..add(
          cardId: 'a',
          albumName: 'TKKG 1',
          undoable: true,
          seriesTitle: 'TKKG',
        );

        async.elapse(const Duration(milliseconds: 100));
        queue.add(cardId: 'b', albumName: 'Random', undoable: false);
        async.elapse(const Duration(milliseconds: 600));

        expect(flushed, hasLength(2));
        expect(flushed[0].cardIds, ['a']);
        expect(flushed[0].undoable, isTrue);
        expect(flushed[1].cardIds, ['b']);
        expect(flushed[1].undoable, isFalse);
        expect(flushed[1].firstAlbumName, 'Random');
      });
    });

    test('flush is a no-op when nothing is pending', () {
      final flushed = <AddSnackBatch>[];
      AddSnackQueue(onFlush: flushed.add).flush();
      expect(flushed, isEmpty);
    });
  });
}
