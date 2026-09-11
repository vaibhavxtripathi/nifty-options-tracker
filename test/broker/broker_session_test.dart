@TestOn('vm')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:nifty_options_tracker/core/config/broker_config.dart';
import 'package:nifty_options_tracker/core/error/failures.dart';
import 'package:nifty_options_tracker/data/broker/angel_client.dart';
import 'package:nifty_options_tracker/data/broker/broker_session.dart';

/// §5.6: the broker session, and the rule that it can never sign a user out.
void main() {
  const configured = BrokerConfig(
    apiKey: 'key',
    clientCode: 'CLIENT',
    mpin: '1234',
    // Valid base32; never a real secret.
    totpSecret: 'GEZDGNBVGY3TQOJQ',
  );

  DateTime ist(int day, int hour, int minute) =>
      DateTime.utc(2026, 9, day, hour, minute)
          .subtract(const Duration(hours: 5, minutes: 30));

  group('the 05:00 IST expiry boundary', () {
    test('a token issued after 05:00 survives the same day', () {
      final client = _FakeClient(configured, issuedAt: ist(11, 9, 0));
      final session = BrokerSession(
        client: client,
        clock: () => ist(11, 23, 0),
      );

      // One login, then reuse — a live token must not be re-fetched.
      expect(session.ensureSession(), completes);
      return session.ensureSession().then((_) async {
        await session.ensureSession();
        expect(client.loginCount, 1);
      });
    });

    test('a token issued before 05:00 is dead after it', () async {
      // The same shape as the contract cache's 08:30 rule: a wall-clock
      // boundary, not an age. A token issued at 04:55 is dead five minutes
      // later, which "expires after 24 hours" would get wrong.
      final client = _FakeClient(configured, issuedAt: ist(11, 4, 55));
      final session = BrokerSession(
        client: client,
        clock: () => ist(11, 5, 30),
      );

      await session.ensureSession();
      await session.ensureSession();

      expect(
        client.loginCount,
        2,
        reason: 'the stale token cannot be refreshed, so it is a fresh login',
      );
    });

    test('yesterday\'s token is expired today', () async {
      final client = _FakeClient(configured, issuedAt: ist(10, 12, 0));
      final session = BrokerSession(
        client: client,
        clock: () => ist(11, 12, 0),
      );

      await session.ensureSession();
      await session.ensureSession();
      expect(client.loginCount, 2);
    });
  });

  group('renewal', () {
    test('prefers a silent refresh over spending a TOTP window', () async {
      final client = _FakeClient(configured, issuedAt: ist(11, 9, 0));
      final session = BrokerSession(
        client: client,
        clock: () => ist(11, 12, 0),
      );

      await session.ensureSession();
      await session.renew();

      expect(client.refreshCount, 1);
      expect(
        client.loginCount,
        1,
        reason: 'refresh needs no TOTP, so it does not burn a window',
      );
    });

    test('falls back to a full login when the refresh is rejected', () async {
      final client = _FakeClient(
        configured,
        issuedAt: ist(11, 9, 0),
        failRefresh: true,
      );
      final session = BrokerSession(
        client: client,
        clock: () => ist(11, 12, 0),
      );

      await session.ensureSession();
      await session.renew();

      expect(client.refreshCount, 1);
      expect(client.loginCount, 2);
    });
  });

  group('concurrent callers share one round trip', () {
    test('a reconnect storm produces exactly one login', () async {
      // Without coalescing, every reconnect attempt would fire its own login.
      // The endpoint is rate-limited and each attempt burns a TOTP window, so
      // that turns a transient blip into a lockout.
      final client = _FakeClient(configured, issuedAt: ist(11, 9, 0));
      final session = BrokerSession(
        client: client,
        clock: () => ist(11, 12, 0),
      );

      await Future.wait([
        session.ensureSession(),
        session.ensureSession(),
        session.ensureSession(),
        session.ensureSession(),
      ]);

      expect(client.loginCount, 1);
    });
  });

  group('the two-auth-systems rule', () {
    test('an unconfigured build fails with BrokerAuthFailure, not Auth', () async {
      const empty = BrokerConfig(
        apiKey: '',
        clientCode: '',
        mpin: '',
        totpSecret: '',
      );
      final session = BrokerSession(
        client: _FakeClient(empty, issuedAt: ist(11, 9, 0), failLogin: true),
        clock: () => ist(11, 12, 0),
      );

      await expectLater(
        session.ensureSession(),
        throwsA(
          allOf(isA<BrokerAuthFailure>(), isNot(isA<AuthFailure>())),
        ),
      );
    });

    test('clearing the broker session says nothing about the app session', () {
      // There is no API here that could reach Firebase — asserted by the
      // architecture test, and reflected in this one being this short.
      final session = BrokerSession(
        client: _FakeClient(configured, issuedAt: ist(11, 9, 0)),
        clock: () => ist(11, 12, 0),
      );
      session.clear();
      expect(session.hasSession, isFalse);
    });
  });

  test('credentials are unavailable until a session exists', () {
    final session = BrokerSession(
      client: _FakeClient(configured, issuedAt: ist(11, 9, 0)),
      clock: () => ist(11, 12, 0),
    );
    expect(session.requireCredentials, throwsA(isA<BrokerAuthFailure>()));
  });

  test('credentials reflect the newest token, not the first', () async {
    // A reconnect after a refresh must present the new JWT. Capturing it at
    // construction is exactly how a reconnect ends up rejected.
    final client = _FakeClient(configured, issuedAt: ist(11, 9, 0));
    final session = BrokerSession(
      client: client,
      clock: () => ist(11, 12, 0),
    );

    await session.ensureSession();
    final first = session.requireCredentials().jwtToken;
    await session.renew();
    final second = session.requireCredentials().jwtToken;

    expect(second, isNot(first));
  });

  test('neither tokens nor config can print a secret', () {
    // The logger bans token material; these objects reach it, so the cheapest
    // way to honour that is to make them structurally unable to print one.
    final tokens = BrokerTokens(
      jwtToken: 'jwt-value',
      refreshToken: 'refresh-value',
      feedToken: 'feed-value',
      issuedAt: ist(11, 9, 0),
    );
    expect(tokens.toString(), isNot(contains('jwt-value')));
    expect(configured.toString(), isNot(contains('GEZDGNBV')));
    expect(configured.toString(), isNot(contains('1234')));
  });
}

final class _FakeClient implements BrokerRestClient {
  _FakeClient(
    this.config, {
    required this.issuedAt,
    this.failLogin = false,
    this.failRefresh = false,
  });

  @override
  final BrokerConfig config;

  final DateTime issuedAt;
  final bool failLogin;
  final bool failRefresh;

  int loginCount = 0;
  int refreshCount = 0;
  int _serial = 0;

  @override
  Future<BrokerTokens> login() async {
    loginCount++;
    if (failLogin || !config.isConfigured) {
      throw const BrokerAuthFailure('not configured');
    }
    return _issue();
  }

  @override
  Future<BrokerTokens> refresh(BrokerTokens current) async {
    refreshCount++;
    if (failRefresh) throw const BrokerAuthFailure('refresh rejected');
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
      issuedAt: issuedAt,
    );
  }
}
