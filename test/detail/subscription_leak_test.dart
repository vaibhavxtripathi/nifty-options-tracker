@TestOn('vm')
library;

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nifty_options_tracker/data/broker/feed_connection.dart';
import 'package:nifty_options_tracker/data/broker/feed_socket.dart';
import 'package:nifty_options_tracker/data/market_data_repository_impl.dart';

/// §7.5: *"open Detail, immediately pop, repeat rapidly — confirm no socket
/// leak."*
///
/// The hardest of the hardening cases, because a leak here is invisible
/// locally: the app looks fine while the server streams instruments nobody is
/// reading, and the symptom only appears later as rate limiting or a stalled
/// feed. Phase 3 shipped exactly this bug once — `stop()` awaited a future
/// that never resolved, so the unsubscribe frame was never sent — and it was
/// only caught because a test counted frames rather than trusting the code.
void main() {
  group('rapid open and close leaves nothing subscribed', () {
    test('a single open/close pair unsubscribes what it subscribed', () {
      fakeAsync((async) {
        final socket = _CountingSocket();
        final repo = _repo(socket);

        final sub = repo.ticks('57379').listen((_) {});
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 20));
        unawaited(sub.cancel());
        async.elapse(const Duration(milliseconds: 200));

        expect(socket.subscribes, 1);
        expect(socket.unsubscribes, 1);
        expect(socket.outstanding, isEmpty);

        unawaited(repo.dispose());
      });
    });

    test('twenty rapid cycles leave nothing outstanding', () {
      // The actual §7.5 gesture: open, pop before anything settles, repeat.
      fakeAsync((async) {
        final socket = _CountingSocket();
        final repo = _repo(socket);

        for (var i = 0; i < 20; i++) {
          final sub = repo.ticks('57379').listen((_) {});
          // Deliberately less than a render interval: pop before the
          // subscribe has had time to settle, which is the race that produced
          // the Phase 3 leak.
          async.elapse(const Duration(milliseconds: 5));
          unawaited(sub.cancel());
          async.elapse(const Duration(milliseconds: 5));
        }
        async.elapse(const Duration(seconds: 2));

        expect(
          socket.outstanding,
          isEmpty,
          reason:
              'every subscribe must be matched by an unsubscribe, or the '
              'server keeps streaming instruments nobody reads',
        );
        expect(socket.unsubscribes, socket.subscribes);

        unawaited(repo.dispose());
      });
    });

    test('cancelling before the subscribe settles still unsubscribes', () {
      // The precise Phase 3 failure: cancel arrives while `start()` is still
      // in flight. Without awaiting it, the removal no-ops, the subscribe
      // lands afterwards, and the token streams forever.
      fakeAsync((async) {
        final socket = _CountingSocket();
        final repo = _repo(socket);

        final sub = repo.ticks('57379').listen((_) {});
        // No elapse at all — cancel in the same turn as the listen.
        unawaited(sub.cancel());
        async.elapse(const Duration(seconds: 1));

        expect(socket.outstanding, isEmpty);

        unawaited(repo.dispose());
      });
    });

    test('different tokens in sequence each clean up', () {
      fakeAsync((async) {
        final socket = _CountingSocket();
        final repo = _repo(socket);

        for (final token in ['57379', '55292', '47423']) {
          final sub = repo.ticks(token).listen((_) {});
          async.elapse(const Duration(milliseconds: 20));
          unawaited(sub.cancel());
          async.elapse(const Duration(milliseconds: 50));
        }
        async.elapse(const Duration(seconds: 1));

        expect(socket.outstanding, isEmpty);
        unawaited(repo.dispose());
      });
    });
  });

  test('only one socket is opened across many screen visits', () {
    // Phase 0 measured that opening sockets in quick succession is itself
    // rate-limited, so a connection per screen visit would throttle the app
    // into looking broken.
    fakeAsync((async) {
      final socket = _CountingSocket();
      final factory = _SingleSocketFactory(socket);
      final repo = MarketDataRepositoryImpl(
        connection: FeedConnection(
          socketFactory: factory,
          clock: _marketOpen,
        ),
      );

      for (var i = 0; i < 10; i++) {
        final sub = repo.ticks('57379').listen((_) {});
        async.elapse(const Duration(milliseconds: 20));
        unawaited(sub.cancel());
        async.elapse(const Duration(milliseconds: 20));
      }

      expect(factory.connectCount, 1, reason: 'the socket is reused');
      unawaited(repo.dispose());
    });
  });
}

DateTime _marketOpen() =>
    DateTime.utc(2026, 9, 11, 12).subtract(const Duration(hours: 5, minutes: 30));

MarketDataRepositoryImpl _repo(_CountingSocket socket) =>
    MarketDataRepositoryImpl(
      connection: FeedConnection(
        socketFactory: _SingleSocketFactory(socket),
        clock: _marketOpen,
      ),
    );

final class _SingleSocketFactory implements FeedSocketFactory {
  _SingleSocketFactory(this._socket);

  final _CountingSocket _socket;
  int connectCount = 0;

  @override
  Future<FeedSocket> connect() async {
    connectCount++;
    return _socket;
  }
}

/// Tracks subscribe/unsubscribe frames by token, so a leak is a non-empty set
/// rather than something to eyeball.
final class _CountingSocket implements FeedSocket {
  final _controller = StreamController<dynamic>.broadcast();
  final Set<String> outstanding = {};

  int subscribes = 0;
  int unsubscribes = 0;

  @override
  int? closeCode;

  @override
  String? closeReason;

  @override
  Stream<dynamic> get messages => _controller.stream;

  @override
  void send(String frame) {
    if (frame == 'ping') return;

    final isSubscribe = frame.contains('"action":1');
    // Tokens appear as quoted digit strings inside `tokens`.
    final tokens = RegExp(r'"(\d{3,})"')
        .allMatches(frame)
        .map((m) => m.group(1)!)
        .toList();

    for (final token in tokens) {
      if (isSubscribe) {
        outstanding.add(token);
        subscribes++;
      } else {
        outstanding.remove(token);
        unsubscribes++;
      }
    }
  }

  @override
  Future<void> close() async {
    if (!_controller.isClosed) await _controller.close();
  }
}
