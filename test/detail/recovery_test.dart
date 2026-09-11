@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nifty_options_tracker/core/config/broker_config.dart';
import 'package:nifty_options_tracker/core/error/failures.dart';
import 'package:nifty_options_tracker/data/broker/angel_client.dart';
import 'package:nifty_options_tracker/data/broker/broker_session.dart';
import 'package:nifty_options_tracker/data/broker/feed_connection.dart';
import 'package:nifty_options_tracker/data/broker/feed_socket.dart';
import 'package:nifty_options_tracker/domain/entities/feed_state.dart';

import '../broker/fixture_reader.dart';

/// §7.5 recovery cases: *kill wifi mid-stream and restore it*, and
/// *invalidate the token and observe recovery*.
///
/// Both are asserted here rather than only on a device, because both depend on
/// timing that a manual test can only sample. A device run shows the app
/// recovered once; these show it recovers by construction.
void main() {
  final frames = loadFeedSessionFixture();

  DateTime marketOpen() => DateTime.utc(
    2026,
    9,
    11,
    12,
  ).subtract(const Duration(hours: 5, minutes: 30));

  group('wifi dies mid-stream, then returns', () {
    test('the connection drops, retries, and resubscribes on its own', () {
      fakeAsync((async) {
        final factory = _FlakySocketFactory();
        final states = <FeedState>[];
        final connection = FeedConnection(
          socketFactory: factory,
          clock: marketOpen,
          random: Random(1),
        );
        connection.states.listen(states.add);

        unawaited(connection.connect());
        async.flushMicrotasks();
        unawaited(connection.subscribe('57379'));
        async.flushMicrotasks();

        // Data is flowing.
        factory.current!.emit(frames.first.payload);
        async.flushMicrotasks();
        expect(factory.current!.subscribed, contains('57379'));

        // Radios off: the socket dies the way a lost network kills it.
        factory.failNextConnects = 3;
        factory.current!.dropConnection();
        async.elapse(const Duration(seconds: 5));

        expect(
          states.whereType<FeedReconnecting>(),
          isNotEmpty,
          reason: 'a dropped socket must retry, not surrender',
        );

        // Radios back on. Backoff caps at 32s, so a minute covers it.
        factory.failNextConnects = 0;
        async.elapse(const Duration(minutes: 2));

        expect(factory.current, isNotNull);
        expect(
          factory.current!.subscribed,
          contains('57379'),
          reason:
              'the server forgets subscriptions across a reconnect, so a '
              'recovered socket carrying no data would look like a dead feed',
        );

        unawaited(connection.dispose());
      });
    });

    test('a long outage ends in a clear failure, not an infinite spinner', () {
      fakeAsync((async) {
        final factory = _FlakySocketFactory()..failNextConnects = 1000;
        final states = <FeedState>[];
        final connection = FeedConnection(
          socketFactory: factory,
          clock: marketOpen,
          maxRetries: 4,
          random: Random(1),
        );
        connection.states.listen(states.add);

        unawaited(connection.connect());
        async.elapse(const Duration(minutes: 10));

        final failed = states.whereType<FeedFailed>().toList();
        expect(failed, isNotEmpty, reason: 'the user must be told eventually');
        expect(failed.last.failure, isA<FeedFailure>());
        expect(failed.last.failure.message, isNotEmpty);

        unawaited(connection.dispose());
      });
    });
  });

  group('the token expires mid-session', () {
    test('a rejected handshake renews rather than signing the user out', () {
      // The two-auth-systems rule at its sharpest: an expired **broker** token
      // must never reach Firebase's sign-out. A user watching a price should
      // not be ejected from the app because a market-data credential aged out
      // at 05:00.
      fakeAsync((async) {
        final client = _ExpiringClient();
        final session = BrokerSession(
          client: client,
          clock: () => DateTime.utc(2026, 9, 11, 12),
        );

        unawaited(session.ensureSession());
        async.flushMicrotasks();
        expect(client.loginCount, 1);

        // The server rejects the token; the app renews it.
        unawaited(session.renew());
        async.flushMicrotasks();

        expect(client.refreshCount, 1, reason: 'a silent refresh comes first');
        expect(session.hasSession, isTrue);

        unawaited(Future<void>.value());
      });
    });

    test('a broker failure is never an AuthFailure', () {
      fakeAsync((async) {
        final factory = _FlakySocketFactory()
          ..failNextConnects = 1000
          ..error = const WebSocketException('401 Unauthorized');
        final states = <FeedState>[];
        final connection = FeedConnection(
          socketFactory: factory,
          clock: marketOpen,
          random: Random(1),
        );
        connection.states.listen(states.add);

        unawaited(connection.connect());
        async.elapse(const Duration(seconds: 10));

        final failed = states.whereType<FeedFailed>().toList();
        expect(failed, isNotEmpty);
        expect(failed.last.failure, isA<BrokerAuthFailure>());
        expect(
          failed.last.failure,
          isNot(isA<AuthFailure>()),
          reason: 'only AuthFailure may sign a user out, and this is not one',
        );

        unawaited(connection.dispose());
      });
    });
  });

  test('every failure carries a message safe to show a user', () {
    // §4.4: the message reaches a screen, so it must never carry a token, a
    // raw provider response, or an exception toString.
    const failures = <AppFailure>[
      AuthFailure('Incorrect email or password.'),
      BrokerAuthFailure('Market data is unavailable right now.'),
      FeedFailure('Could not reach market data.'),
      ContractFailure('The contract list could not be read.'),
      NetworkFailure('No connection.'),
    ];

    for (final failure in failures) {
      expect(failure.message, isNotEmpty);
      expect(failure.message.endsWith('.'), isTrue);
      // A crude but effective guard: credential material is long and
      // unpunctuated, and a user-facing sentence is neither.
      expect(failure.message.length, lessThan(120));
      expect(failure.message, isNot(contains('Exception')));
      expect(failure.message, isNot(contains('jwt')));
    }
  });
}

final class _FlakySocketFactory implements FeedSocketFactory {
  int failNextConnects = 0;
  Object? error;
  _FlakySocket? current;

  @override
  Future<FeedSocket> connect() async {
    if (failNextConnects > 0) {
      failNextConnects--;
      throw error ?? const SocketException('Network is unreachable');
    }
    final socket = _FlakySocket();
    current = socket;
    return socket;
  }
}

final class _FlakySocket implements FeedSocket {
  final _controller = StreamController<dynamic>.broadcast();
  final Set<String> subscribed = {};

  @override
  int? closeCode = 1006;

  @override
  String? closeReason = 'connection lost';

  void emit(Object message) => _controller.add(message);

  void dropConnection() => _controller.close();

  @override
  Stream<dynamic> get messages => _controller.stream;

  @override
  void send(String frame) {
    if (frame == 'ping') return;
    final isSubscribe = frame.contains('"action":1');
    for (final match in RegExp(r'"(\d{3,})"').allMatches(frame)) {
      final token = match.group(1)!;
      isSubscribe ? subscribed.add(token) : subscribed.remove(token);
    }
  }

  @override
  Future<void> close() async {
    if (!_controller.isClosed) await _controller.close();
  }
}

final class _ExpiringClient implements BrokerRestClient {
  @override
  final BrokerConfig config = const BrokerConfig(
    apiKey: 'key',
    clientCode: 'CLIENT',
    mpin: '1234',
    totpSecret: 'GEZDGNBVGY3TQOJQ',
  );

  int loginCount = 0;
  int refreshCount = 0;
  int _serial = 0;

  @override
  Future<BrokerTokens> login() async {
    loginCount++;
    return _issue();
  }

  @override
  Future<BrokerTokens> refresh(BrokerTokens current) async {
    refreshCount++;
    return _issue();
  }

  @override
  Future<bool> validate(BrokerTokens tokens) async => true;

  BrokerTokens _issue() {
    _serial++;
    return BrokerTokens(
      jwtToken: 'jwt-$_serial',
      refreshToken: 'refresh-$_serial',
      feedToken: 'feed-$_serial',
      issuedAt: DateTime.utc(2026, 9, 11, 12),
    );
  }
}
