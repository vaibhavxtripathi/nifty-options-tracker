@TestOn('vm')
library;

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nifty_options_tracker/data/broker/conflate.dart';

/// The shared conflation transformer (§5.7).
///
/// Extracted from the repository so the live path, the replay path and the
/// repository all use one implementation — a demo that rendered differently
/// from production would be demonstrating the wrong thing.
void main() {
  test('the first value is emitted immediately', () {
    fakeAsync((async) {
      final source = StreamController<int>();
      final seen = <int>[];
      conflate(source.stream).listen(seen.add);
      async.flushMicrotasks();

      source.add(1);
      async.flushMicrotasks();

      expect(seen, [1], reason: 'a blank screen on open reads as loading');
      unawaited(source.close());
    });
  });

  test('a burst collapses to one emission per interval', () {
    fakeAsync((async) {
      final source = StreamController<int>();
      final seen = <int>[];
      conflate(source.stream).listen(seen.add);
      async.flushMicrotasks();

      for (var i = 0; i < 50; i++) {
        source.add(i);
      }
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 250));

      expect(seen.length, lessThan(10));
      expect(seen.last, 49, reason: 'the newest value always wins');
      unawaited(source.close());
    });
  });

  test('it keeps emitting under continuous traffic, unlike a debounce', () {
    // The decisive difference. A debounce waits for a quiet gap that a live
    // feed never provides, so the screen would freeze during exactly the
    // activity worth watching.
    fakeAsync((async) {
      final source = StreamController<int>();
      final seen = <int>[];
      conflate(source.stream).listen(seen.add);
      async.flushMicrotasks();

      for (var i = 0; i < 40; i++) {
        source.add(i);
        async.elapse(const Duration(milliseconds: 25));
      }

      expect(seen.length, greaterThan(5));
      unawaited(source.close());
    });
  });

  test('no value is emitted twice when nothing new arrives', () {
    fakeAsync((async) {
      final source = StreamController<int>();
      final seen = <int>[];
      conflate(source.stream).listen(seen.add);
      async.flushMicrotasks();

      source.add(7);
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 2));

      expect(seen, [7], reason: 'an idle feed must not repeat itself');
      unawaited(source.close());
    });
  });

  test('a pending value is flushed when the source closes', () {
    fakeAsync((async) {
      final source = StreamController<int>();
      final seen = <int>[];
      conflate(source.stream).listen(seen.add);
      async.flushMicrotasks();

      source.add(1);
      async.flushMicrotasks();
      source.add(2);
      unawaited(source.close());
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 200));

      expect(seen, [1, 2], reason: 'the last value must not be swallowed');
    });
  });

  test('errors pass through rather than being conflated away', () {
    fakeAsync((async) {
      final source = StreamController<int>();
      Object? caught;
      conflate(source.stream).listen((_) {}, onError: (Object e) => caught = e);
      async.flushMicrotasks();

      source.addError(StateError('boom'));
      async.flushMicrotasks();

      expect(caught, isA<StateError>());
      unawaited(source.close());
    });
  });

  test('cancelling stops the timer so no screen leaks one', () {
    fakeAsync((async) {
      final source = StreamController<int>();
      final seen = <int>[];
      final sub = conflate(source.stream).listen(seen.add);
      async.flushMicrotasks();

      source.add(1);
      async.flushMicrotasks();
      unawaited(sub.cancel());
      async.flushMicrotasks();

      source.add(2);
      async.elapse(const Duration(seconds: 1));

      expect(seen, [1]);
      unawaited(source.close());
    });
  });
}
