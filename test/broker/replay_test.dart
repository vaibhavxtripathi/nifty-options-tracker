@TestOn('vm')
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nifty_options_tracker/data/broker/replay_feed_connection.dart';

import 'fixture_reader.dart';

/// §6 criterion 7: replay mode emits ticks with realistic timing.
///
/// "Realistic" is the load-bearing word. A fixed-interval replay would emit
/// 141 ticks evenly and make the Phase 4 conflation look effective without
/// ever having met a burst. These tests assert the recorded gaps are actually
/// reproduced.
void main() {
  final frames = loadFeedSessionFixture();

  test('the container parses to the recording we captured', () {
    expect(frames, hasLength(141));
    expect(frames.first.arrivedAt.year, 2026);
    // 180 seconds of wall clock, as the capture reported.
    final span = frames.last.arrivedAt.difference(frames.first.arrivedAt);
    expect(span.inSeconds, inInclusiveRange(175, 185));
  });

  group('criterion 7 — realistic timing', () {
    test('emits every recorded tick', () {
      fakeAsync((async) {
        final replay = ReplayFeedConnection(frames: frames);
        final ticks = <String>[];
        replay.ticks.listen((t) => ticks.add(t.token));

        async.elapse(const Duration(minutes: 5));

        expect(ticks, hasLength(141));
        expect(ticks.toSet(), {'57379', '55292'});
        unawaited(replay.dispose());
      });
    });

    test('reproduces the original inter-arrival gaps', () {
      fakeAsync((async) {
        final replay = ReplayFeedConnection(frames: frames);
        final start = async.elapsed;
        final arrivals = <Duration>[];
        replay.ticks.listen((_) => arrivals.add(async.elapsed - start));

        async.elapse(const Duration(minutes: 5));

        expect(arrivals, hasLength(141));

        // Each emission should land at the recorded offset from the first
        // frame, within a millisecond of rounding.
        final origin = frames.first.arrivedAt;
        for (var i = 0; i < frames.length; i++) {
          final expected = frames[i].arrivedAt.difference(origin);
          expect(
            (arrivals[i] - expected).inMilliseconds.abs(),
            lessThanOrEqualTo(2),
            reason: 'frame $i should arrive at its recorded offset',
          );
        }
        unawaited(replay.dispose());
      });
    });

    test('the gaps are genuinely uneven, so this is not a fixed interval', () {
      // Guards the test above from passing against a metronome: if the
      // recording had uniform gaps, "reproduces the gaps" would prove nothing.
      final origin = frames.first.arrivedAt;
      final gaps = <int>[];
      for (var i = 1; i < frames.length; i++) {
        gaps.add(
          frames[i].arrivedAt.difference(frames[i - 1].arrivedAt).inMilliseconds,
        );
      }
      final shortest = gaps.reduce((a, b) => a < b ? a : b);
      final longest = gaps.reduce((a, b) => a > b ? a : b);
      expect(
        longest,
        greaterThan(shortest * 5),
        reason: 'a real feed bursts and idles; this recording must too',
      );
      expect(origin.isBefore(frames.last.arrivedAt), isTrue);
    });

    test('speed scales the timeline without dropping ticks', () {
      fakeAsync((async) {
        final replay = ReplayFeedConnection(frames: frames, speed: 10);
        final ticks = <Object>[];
        replay.ticks.listen(ticks.add);

        // A tenth of the recorded span is enough at 10x.
        async.elapse(const Duration(seconds: 30));

        expect(ticks, hasLength(141), reason: 'faster, not lossier');
        unawaited(replay.dispose());
      });
    });

    test('the stream closes at the end unless looping', () {
      fakeAsync((async) {
        final replay = ReplayFeedConnection(frames: frames);
        var done = false;
        replay.ticks.listen((_) {}, onDone: () => done = true);

        async.elapse(const Duration(minutes: 5));
        expect(done, isTrue);
        unawaited(replay.dispose());
      });
    });

    test('looping restarts instead of closing', () {
      fakeAsync((async) {
        final replay = ReplayFeedConnection(frames: frames, loop: true);
        var done = false;
        var count = 0;
        replay.ticks.listen((_) => count++, onDone: () => done = true);

        async.elapse(const Duration(minutes: 7));

        expect(done, isFalse);
        expect(count, greaterThan(141), reason: 'it wrapped around');
        unawaited(replay.dispose());
      });
    });

    test('stopping halts emission', () {
      fakeAsync((async) {
        final replay = ReplayFeedConnection(frames: frames);
        var count = 0;
        replay.ticks.listen((_) => count++);

        async.elapse(const Duration(seconds: 60));
        final atStop = count;
        replay.stop();
        async.elapse(const Duration(minutes: 3));

        expect(count, atStop);
        unawaited(replay.dispose());
      });
    });
  });

  group('the container format rejects bad input', () {
    test('a wrong magic is refused', () {
      final bytes = Uint8List(64);
      expect(() => parseRecordedSession(bytes), throwsFormatException);
    });

    test('a truncated record is refused rather than partly read', () {
      final full = loadFixtureBytes();
      final cut = Uint8List.sublistView(full, 0, full.length - 100);
      expect(() => parseRecordedSession(cut), throwsFormatException);
    });

    test('a file shorter than its header is refused', () {
      expect(() => parseRecordedSession(Uint8List(4)), throwsFormatException);
    });
  });

  test('replay reports the span it covers', () {
    final replay = ReplayFeedConnection(frames: frames);
    expect(replay.frameCount, 141);
    expect(replay.duration.inSeconds, inInclusiveRange(175, 185));
  });

  test('a non-positive speed is rejected', () {
    expect(
      () => ReplayFeedConnection(frames: frames, speed: 0),
      throwsArgumentError,
    );
  });
}
