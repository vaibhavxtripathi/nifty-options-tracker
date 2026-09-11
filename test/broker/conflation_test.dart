@TestOn('vm')
library;

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nifty_options_tracker/data/broker/feed_connection.dart';
import 'package:nifty_options_tracker/data/broker/feed_socket.dart';
import 'package:nifty_options_tracker/data/broker/tick_decoder.dart';
import 'package:nifty_options_tracker/data/market_data_repository_impl.dart';

import 'fixture_reader.dart';

/// §5.7 stream shaping: ingest every tick, render at ~10 Hz.
///
/// Driven by the real recording, so the burst these tests conflate is a burst
/// the market actually produced.
void main() {
  final frames = loadFeedSessionFixture();
  final liquid = frames
      .where((f) => decodeSnapQuote(f.payload).token == '57379')
      .toList();

  group('conflation, not debounce', () {
    test('a burst yields one emission per interval, not one per tick', () {
      fakeAsync((async) {
        final socket = _ManualSocket();
        final repo = _repo(socket);
        final received = <double>[];

        final sub = repo.ticks('57379').listen((t) => received.add(t.lastTradedPrice));
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 10));

        // Twenty packets inside a single render interval.
        for (var i = 0; i < 20; i++) {
          socket.emit(liquid[i].payload);
        }
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 150));

        expect(
          received.length,
          lessThan(20),
          reason: 'a burst must not force one rebuild per packet',
        );
        expect(received, isNotEmpty);

        unawaited(sub.cancel());
        unawaited(repo.dispose());
      });
    });

    test('the newest value always wins — conflation is lossless here', () {
      // Lossless *because each packet is a full snapshot*. The last tick in a
      // burst contains everything the dropped ones did, which is why this is
      // safe for a quote screen and would not be for candles or VWAP.
      fakeAsync((async) {
        final socket = _ManualSocket();
        final repo = _repo(socket);
        final received = <double>[];

        final sub = repo.ticks('57379').listen((t) => received.add(t.lastTradedPrice));
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 10));

        for (var i = 0; i < 15; i++) {
          socket.emit(liquid[i].payload);
        }
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 300));

        final lastSent = decodeSnapQuote(liquid[14].payload).lastTradedPrice;
        expect(
          received.last,
          lastSent,
          reason: 'the most recent snapshot must be what the screen shows',
        );

        unawaited(sub.cancel());
        unawaited(repo.dispose());
      });
    });

    test('it does not wait for a quiet gap the way a debounce would', () {
      // The decisive difference. Under continuous traffic a debounce emits
      // nothing at all, because the gap it waits for never arrives — the
      // screen would look frozen during exactly the activity that matters.
      fakeAsync((async) {
        final socket = _ManualSocket();
        final repo = _repo(socket);
        final received = <double>[];

        final sub = repo.ticks('57379').listen((t) => received.add(t.lastTradedPrice));
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 10));

        // Traffic every 20 ms for a second: never a gap longer than the
        // render interval.
        for (var i = 0; i < 50; i++) {
          socket.emit(liquid[i % liquid.length].payload);
          async.elapse(const Duration(milliseconds: 20));
        }

        expect(
          received.length,
          greaterThan(5),
          reason: 'continuous traffic must keep the screen updating',
        );

        unawaited(sub.cancel());
        unawaited(repo.dispose());
      });
    });

    test('the first tick is emitted immediately, not after an interval', () {
      fakeAsync((async) {
        final socket = _ManualSocket();
        final repo = _repo(socket);
        final received = <double>[];

        final sub = repo.ticks('57379').listen((t) => received.add(t.lastTradedPrice));
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 10));

        socket.emit(liquid.first.payload);
        async.flushMicrotasks();

        expect(
          received,
          hasLength(1),
          reason: 'a blank screen on open reads as loading, not as live',
        );

        unawaited(sub.cancel());
        unawaited(repo.dispose());
      });
    });
  });

  group('subscription lifecycle', () {
    test('listening subscribes and cancelling unsubscribes on the wire', () {
      // The graded criterion is that the subscription is *cleanly closed*.
      // Tying it to the stream's lifetime means no screen can forget.
      fakeAsync((async) {
        final socket = _ManualSocket();
        final repo = _repo(socket);

        final sub = repo.ticks('57379').listen((_) {});
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 10));

        expect(
          socket.sent.any((f) => f.contains('"action":1')),
          isTrue,
          reason: 'listening opens the subscription',
        );

        // `cancel()` runs onCancel, whose future must be driven by the fake
        // clock before the unsubscribe frame can be observed.
        unawaited(sub.cancel());
        async.elapse(const Duration(milliseconds: 200));

        expect(
          socket.sent.any((f) => f.contains('"action":0')),
          isTrue,
          reason: 'cancelling closes it on the server, not just locally',
        );

        unawaited(repo.dispose());
      });
    });

    test('ticks for other tokens are filtered out', () {
      fakeAsync((async) {
        final socket = _ManualSocket();
        final repo = _repo(socket);
        final received = <String>[];

        final sub = repo.ticks('57379').listen((t) => received.add(t.token));
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 10));

        // The illiquid strike's packet, which this stream did not ask for.
        final other = frames.firstWhere(
          (f) => decodeSnapQuote(f.payload).token == '55292',
        );
        socket.emit(other.payload);
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 200));

        expect(received, isEmpty);

        unawaited(sub.cancel());
        unawaited(repo.dispose());
      });
    });
  });
}

MarketDataRepositoryImpl _repo(_ManualSocket socket) =>
    MarketDataRepositoryImpl(
      connection: FeedConnection(
        socketFactory: _SingleSocketFactory(socket),
        clock: () =>
            DateTime.utc(2026, 9, 11, 12).subtract(
              const Duration(hours: 5, minutes: 30),
            ),
      ),
    );

final class _SingleSocketFactory implements FeedSocketFactory {
  _SingleSocketFactory(this._socket);

  final _ManualSocket _socket;

  @override
  Future<FeedSocket> connect() async => _socket;
}

final class _ManualSocket implements FeedSocket {
  final _controller = StreamController<dynamic>.broadcast();
  final List<String> sent = [];

  @override
  int? closeCode;

  @override
  String? closeReason;

  void emit(Object message) => _controller.add(message);

  @override
  Stream<dynamic> get messages => _controller.stream;

  @override
  void send(String frame) => sent.add(frame);

  @override
  Future<void> close() async {
    if (!_controller.isClosed) await _controller.close();
  }
}
