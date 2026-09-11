@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nifty_options_tracker/core/error/failures.dart';
import 'package:nifty_options_tracker/data/broker/feed_connection.dart';
import 'package:nifty_options_tracker/data/broker/feed_frames.dart';
import 'package:nifty_options_tracker/data/broker/feed_socket.dart';
import 'package:nifty_options_tracker/domain/entities/feed_state.dart';

import 'fixture_reader.dart';

/// §6 criterion 6: a fake socket proves the backoff sequence, the 10-second
/// ping, and resubscribe-on-reconnect.
///
/// These are behaviours about *timing and ordering*. None of them can be
/// asserted against the live server — you cannot ask Angel One to drop your
/// connection on cue — so the socket is injected and `fakeAsync` drives the
/// clock. That is the whole reason `FeedSocketFactory` exists.
void main() {
  final frames = loadFeedSessionFixture();

  group('the 10-second ping', () {
    test('is sent every 10 seconds while connected', () {
      fakeAsync((async) {
        final factory = _FakeSocketFactory();
        final connection = _build(factory);

        unawaited(connection.connect());
        async.flushMicrotasks();

        final socket = factory.sockets.single;
        expect(socket.sent.where((f) => f == pingFrame), isEmpty);

        async.elapse(const Duration(seconds: 10));
        expect(socket.pings, 1);

        async.elapse(const Duration(seconds: 30));
        expect(socket.pings, 4, reason: 'one per 10s, no more and no fewer');

        unawaited(connection.dispose());
      });
    });

    test('stops once disconnected, so a dead socket is not written to', () {
      fakeAsync((async) {
        final factory = _FakeSocketFactory();
        final connection = _build(factory);

        unawaited(connection.connect());
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 25));
        final before = factory.sockets.single.pings;

        unawaited(connection.disconnect());
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 60));

        expect(factory.sockets.single.pings, before);
        unawaited(connection.dispose());
      });
    });
  });

  group('backoff', () {
    test('grows exponentially and is capped', () {
      fakeAsync((async) {
        // Always-failing factory, so every attempt produces a delay to observe.
        final factory = _FakeSocketFactory(failEveryConnect: true);
        final states = <FeedState>[];
        final connection = _build(factory, seed: 1);
        connection.states.listen(states.add);

        unawaited(connection.connect());
        async.elapse(const Duration(minutes: 10));

        final delays = states
            .whereType<FeedReconnecting>()
            .map((s) => s.nextDelay)
            .toList();

        expect(delays, isNotEmpty, reason: 'a failed connect must retry');

        // Jitter makes exact values untestable by design, so assert the
        // property that matters: each delay sits inside [50%, 100%] of the
        // capped exponential for its attempt.
        for (var i = 0; i < delays.length; i++) {
          final ideal = min(1000 * pow(2, i).toInt(), 32000);
          expect(
            delays[i].inMilliseconds,
            inInclusiveRange(ideal ~/ 2, ideal),
            reason: 'attempt $i should back off around ${ideal}ms',
          );
        }

        unawaited(connection.dispose());
      });
    });

    test('backs off from the very first retry, not after several', () {
      // Phase 0 finding: a tight retry loop is itself what keeps the socket
      // shut, because connections are rate-limited. So retry 1 must already
      // wait, rather than hammering and only backing off once it has failed
      // a few times.
      fakeAsync((async) {
        final factory = _FakeSocketFactory(failEveryConnect: true);
        final connection = _build(factory, seed: 1);

        unawaited(connection.connect());
        async.flushMicrotasks();

        final attemptsImmediately = factory.connectCount;
        async.elapse(const Duration(milliseconds: 400));
        expect(
          factory.connectCount,
          attemptsImmediately,
          reason: 'no immediate retry — the first one already backs off',
        );

        unawaited(connection.dispose());
      });
    });

    test('gives up after the retry budget and reports FeedFailure', () {
      fakeAsync((async) {
        final factory = _FakeSocketFactory(failEveryConnect: true);
        final states = <FeedState>[];
        final connection = _build(factory, seed: 1, maxRetries: 3);
        connection.states.listen(states.add);

        unawaited(connection.connect());
        async.elapse(const Duration(minutes: 5));

        final failed = states.whereType<FeedFailed>().toList();
        expect(failed, isNotEmpty);
        expect(failed.last.failure, isA<FeedFailure>());
        expect(factory.connectCount, lessThanOrEqualTo(4));

        unawaited(connection.dispose());
      });
    });
  });

  group('the rate-limit rejection is retryable, never fatal-auth', () {
    // The highest-consequence classification in the file. Phase 0 measured
    // that a throttled handshake produces the *same* error as an
    // unauthenticated one, so mapping it to auth would turn a two-second
    // delay into a full re-login.
    test('"connection closed before full header" retries', () {
      fakeAsync((async) {
        final factory = _FakeSocketFactory(
          failEveryConnect: true,
          error: const HttpException(
            'Connection closed before full header was received',
          ),
        );
        final states = <FeedState>[];
        final connection = _build(factory, seed: 1);
        connection.states.listen(states.add);

        unawaited(connection.connect());
        async.elapse(const Duration(seconds: 30));

        expect(
          states.whereType<FeedReconnecting>(),
          isNotEmpty,
          reason: 'throttling must be retried, not surfaced as a credential '
              'failure',
        );
        expect(
          states.whereType<FeedFailed>().where(
            (s) => s.failure is BrokerAuthFailure,
          ),
          isEmpty,
        );

        unawaited(connection.dispose());
      });
    });

    test('a genuine 401 does surface as BrokerAuthFailure', () {
      fakeAsync((async) {
        final factory = _FakeSocketFactory(
          failEveryConnect: true,
          error: const WebSocketException('401 Unauthorized'),
        );
        final states = <FeedState>[];
        final connection = _build(factory, seed: 1);
        connection.states.listen(states.add);

        unawaited(connection.connect());
        async.elapse(const Duration(seconds: 5));

        final failed = states.whereType<FeedFailed>().toList();
        expect(failed, isNotEmpty);
        expect(failed.last.failure, isA<BrokerAuthFailure>());
        // And critically, never an AuthFailure — that is the only failure
        // permitted to sign a user out of the app.
        expect(failed.last.failure, isNot(isA<AuthFailure>()));

        unawaited(connection.dispose());
      });
    });
  });

  group('resubscribe on reconnect', () {
    test('the desired set is re-applied to a new socket', () {
      // The server does not remember subscriptions across a reconnect, so
      // without this a reconnect yields a healthy socket carrying no data —
      // which looks like a dead feed rather than a missing frame.
      fakeAsync((async) {
        final factory = _FakeSocketFactory();
        final connection = _build(factory, seed: 1);

        unawaited(connection.connect());
        async.flushMicrotasks();
        unawaited(connection.subscribe('57379'));
        unawaited(connection.subscribe('55292'));
        async.flushMicrotasks();

        expect(factory.sockets.single.subscribedTokens, {'57379', '55292'});

        // Drop it the way a server would.
        factory.sockets.single.dropConnection();
        async.elapse(const Duration(seconds: 10));

        expect(factory.sockets.length, 2, reason: 'it reconnected');
        expect(
          factory.sockets.last.subscribedTokens,
          {'57379', '55292'},
          reason: 'both subscriptions were re-applied to the new socket',
        );

        unawaited(connection.dispose());
      });
    });

    test('an unsubscribed token is not restored on reconnect', () {
      fakeAsync((async) {
        final factory = _FakeSocketFactory();
        final connection = _build(factory, seed: 1);

        unawaited(connection.connect());
        async.flushMicrotasks();
        unawaited(connection.subscribe('57379'));
        unawaited(connection.subscribe('55292'));
        async.flushMicrotasks();
        unawaited(connection.unsubscribe('55292'));
        async.flushMicrotasks();

        factory.sockets.single.dropConnection();
        async.elapse(const Duration(seconds: 10));

        expect(factory.sockets.last.subscribedTokens, {'57379'});
        unawaited(connection.dispose());
      });
    });

    test('unsubscribe sends a frame, so the server stops streaming', () {
      fakeAsync((async) {
        final factory = _FakeSocketFactory();
        final connection = _build(factory);

        unawaited(connection.connect());
        async.flushMicrotasks();
        unawaited(connection.subscribe('57379'));
        async.flushMicrotasks();
        unawaited(connection.unsubscribe('57379'));
        async.flushMicrotasks();

        expect(
          factory.sockets.single.sent.any((f) => f.contains('"action":0')),
          isTrue,
          reason: 'local state alone would leave the server streaming',
        );
        unawaited(connection.dispose());
      });
    });
  });

  group('frame handling', () {
    test('binary market data becomes ticks', () {
      fakeAsync((async) {
        final factory = _FakeSocketFactory();
        final connection = _build(factory);
        final ticks = <String>[];
        connection.ticks.listen((t) => ticks.add(t.token));

        unawaited(connection.connect());
        async.flushMicrotasks();

        factory.sockets.single.emit(frames.first.payload);
        async.flushMicrotasks();

        expect(ticks, ['57379']);
        unawaited(connection.dispose());
      });
    });

    test('a "pong" text frame is never parsed as a packet', () {
      // Phase 0: the server replies "pong" as text and sends one on connect
      // before any ping. A decoder fed that would reject it, but the stream
      // must not carry a tick for it either.
      fakeAsync((async) {
        final factory = _FakeSocketFactory();
        final connection = _build(factory);
        final ticks = <String>[];
        connection.ticks.listen((t) => ticks.add(t.token));

        unawaited(connection.connect());
        async.flushMicrotasks();

        factory.sockets.single.emit(pongFrame);
        factory.sockets.single.emit(pongFrame);
        async.flushMicrotasks();

        expect(ticks, isEmpty);
        unawaited(connection.dispose());
      });
    });

    test('a malformed binary frame is dropped without killing the stream', () {
      fakeAsync((async) {
        final factory = _FakeSocketFactory();
        final connection = _build(factory);
        final ticks = <String>[];
        connection.ticks.listen((t) => ticks.add(t.token));

        unawaited(connection.connect());
        async.flushMicrotasks();

        factory.sockets.single.emit(List<int>.filled(51, 0));
        factory.sockets.single.emit(frames.first.payload);
        async.flushMicrotasks();

        expect(ticks, ['57379'], reason: 'the good frame still arrived');
        unawaited(connection.dispose());
      });
    });
  });

  group('the staleness watchdog is gated on the clock', () {
    test('silence outside market hours does not trigger a reconnect', () {
      // Angel One sends no segment-status frame, so a quiet socket at 16:00 is
      // a closed market. Reconnecting on that would be a retry loop that
      // cannot succeed, and would trip the rate limit for nothing.
      fakeAsync((async) {
        final closed = DateTime.utc(2026, 9, 11, 16, 0).subtract(istOffsetTest);
        final factory = _FakeSocketFactory();
        // Advancing clock, exactly as in the market-open case below: if this
        // were frozen the test would pass because no time appeared to elapse,
        // not because the market gate held.
        final start = async.elapsed;
        final connection = _build(
          factory,
          clock: () => closed.add(async.elapsed - start),
        );

        unawaited(connection.connect());
        async.flushMicrotasks();
        async.elapse(const Duration(minutes: 5));

        expect(factory.connectCount, 1, reason: 'no reconnect while closed');
        unawaited(connection.dispose());
      });
    });

    test('silence during market hours does trigger one', () {
      fakeAsync((async) {
        final open = DateTime.utc(2026, 9, 11, 12, 0).subtract(istOffsetTest);
        final factory = _FakeSocketFactory();
        // The clock must advance with the fake timers, or the watchdog can
        // never observe elapsed silence — `now - lastMessage` would be zero
        // forever and the test would pass for the wrong reason.
        final start = async.elapsed;
        final connection = _build(
          factory,
          clock: () => open.add(async.elapsed - start),
        );

        unawaited(connection.connect());
        async.flushMicrotasks();
        async.elapse(const Duration(minutes: 5));

        expect(
          factory.connectCount,
          greaterThan(1),
          reason: 'a half-open socket delivers nothing and reports healthy',
        );
        unawaited(connection.dispose());
      });
    });
  });
}

const Duration istOffsetTest = Duration(hours: 5, minutes: 30);

FeedConnection _build(
  _FakeSocketFactory factory, {
  int? seed,
  int maxRetries = 8,
  DateTime Function()? clock,
}) {
  // Default to a mid-session instant so the watchdog's market gate is open
  // unless a test says otherwise.
  final marketOpen = DateTime.utc(2026, 9, 11, 12, 0).subtract(istOffsetTest);
  return FeedConnection(
    socketFactory: factory,
    maxRetries: maxRetries,
    clock: clock ?? () => marketOpen,
    random: seed == null ? null : Random(seed),
  );
}

final class _FakeSocketFactory implements FeedSocketFactory {
  _FakeSocketFactory({this.failEveryConnect = false, this.error});

  final bool failEveryConnect;
  final Object? error;

  final List<_FakeSocket> sockets = [];
  int connectCount = 0;

  @override
  Future<FeedSocket> connect() async {
    connectCount++;
    if (failEveryConnect) {
      throw error ?? const SocketException('refused');
    }
    final socket = _FakeSocket();
    sockets.add(socket);
    return socket;
  }
}

final class _FakeSocket implements FeedSocket {
  final _controller = StreamController<dynamic>.broadcast();
  final List<String> sent = [];

  @override
  int? closeCode = 1001;

  @override
  String? closeReason = 'Connection Idle Timeout';

  int get pings => sent.where((f) => f == pingFrame).length;

  /// Tokens the connection has asked this socket to stream, derived from the
  /// frames actually sent rather than from the connection's internal state —
  /// otherwise the test would be asserting against itself.
  Set<String> get subscribedTokens {
    final tokens = <String>{};
    for (final frame in sent) {
      if (frame == pingFrame) continue;
      final isSubscribe = frame.contains('"action":1');
      final matches = RegExp(r'"([0-9]+)"').allMatches(frame);
      for (final match in matches) {
        final token = match.group(1)!;
        if (isSubscribe) {
          tokens.add(token);
        } else {
          tokens.remove(token);
        }
      }
    }
    return tokens;
  }

  void emit(Object message) => _controller.add(message);

  void dropConnection() => _controller.close();

  @override
  Stream<dynamic> get messages => _controller.stream;

  @override
  void send(String frame) => sent.add(frame);

  @override
  Future<void> close() async {
    if (!_controller.isClosed) await _controller.close();
  }
}
